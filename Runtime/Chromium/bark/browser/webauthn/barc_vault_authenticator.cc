#include "bark/browser/webauthn/barc_vault_authenticator.h"

#include <algorithm>
#include <utility>

#include "base/base64url.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "components/cbor/reader.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "device/fido/attestation_object.h"
#include "device/fido/authenticator_get_assertion_response.h"
#include "device/fido/authenticator_make_credential_response.h"
#include "device/fido/authenticator_supported_options.h"
#include "device/fido/ctap_get_assertion_request.h"
#include "device/fido/ctap_make_credential_request.h"
#include "device/fido/fido_authenticator.h"
#include "device/fido/fido_discovery_base.h"
#include "url/origin.h"

namespace barc {
namespace {
using MakeStatus = device::MakeCredentialStatus;
using GetStatus = device::GetAssertionStatus;
std::string Encode(base::span<const uint8_t> bytes) {
  std::string result;
  base::Base64UrlEncode(bytes, base::Base64UrlEncodePolicy::OMIT_PADDING, &result);
  return result;
}
std::optional<std::vector<uint8_t>> Decode(const base::DictValue& value,
                                          std::string_view key) {
  const auto* encoded = value.FindString(key);
  std::string bytes;
  if (!encoded || encoded->size() > 65536 ||
      !base::Base64UrlDecode(*encoded, base::Base64UrlDecodePolicy::DISALLOW_PADDING, &bytes))
    return std::nullopt;
  return std::vector<uint8_t>(bytes.begin(), bytes.end());
}
class PawlAuthenticator final : public device::FidoAuthenticator {
 public:
  PawlAuthenticator(content::RenderFrameHost* frame, url::Origin origin,
                    std::string rp,base::RepeatingCallback<bool()> current)
      : document_(frame->GetWeakDocumentPtr()), origin_(std::move(origin)), rp_(std::move(rp)), current_(std::move(current)) {}
  ~PawlAuthenticator() override { Cancel(); }
  void InitializeAuthenticator(base::OnceClosure callback) override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,std::move(callback));
  }
  void MakeCredential(device::CtapMakeCredentialRequest request,
                      device::MakeCredentialOptions options,
                      MakeCredentialCallback callback) override {
    Cancel();
    make_callback_ = std::move(callback);
    const bool es256 = std::ranges::any_of(request.public_key_credential_params.public_key_credential_params(),
        [](const auto& parameter) { return parameter.algorithm == -7; });
    if (!Current() || request.rp.id != rp_ || !es256 || request.hmac_secret || request.prf ||
        request.hmac_secret_mc || request.prf_input || request.cmtg_key || request.large_blob_key ||
        request.large_blob_support != device::LargeBlobSupport::kNotRequested ||
        request.cred_blob || request.app_id_exclude || request.min_pin_length_requested ||
        request.cred_protect_enforce || options.is_passkey_upgrade_request ||
        options.authenticator_attachment == device::AuthenticatorAttachment::kCrossPlatform ||
        options.large_blob_support != device::LargeBlobSupport::kNotRequested) {
      FinishMake(MakeStatus::kAuthenticatorResponseInvalid,std::nullopt); return;
    }
    base::DictValue args;
    args.Set("rpId",rp_); args.Set("rpName",request.rp.name.value_or(rp_));
    args.Set("origin",origin_.Serialize()); args.Set("clientDataHash",Encode(request.client_data_hash));
    base::DictValue user;
    user.Set("id",Encode(request.user.id)); user.Set("name",request.user.name.value_or(""));
    user.Set("displayName",request.user.display_name.value_or("")); args.Set("user",std::move(user));
    base::ListValue algorithms; algorithms.Append(-7); args.Set("pubKeyCredParams",std::move(algorithms));
    base::ListValue excluded;
    for (const auto& credential : request.exclude_list) excluded.Append(Encode(credential.id));
    args.Set("excludeCredentials",std::move(excluded));
    cancel_ = StartVaultPasskeyRequest(document_.AsRenderFrameHostIfValid(),origin_,0,std::move(args),
        base::BindOnce(&PawlAuthenticator::Made,weak_factory_.GetWeakPtr()));
  }
  void GetAssertion(device::CtapGetAssertionRequest request,
                    device::CtapGetAssertionOptions options,
                    GetAssertionCallback callback) override {
    Cancel(); get_callback_ = std::move(callback);
    if (!Current() || request.rp_id != rp_ || request.app_id ||
        request.alternative_application_parameter || request.hmac_secret || request.large_blob_key ||
        request.get_cred_blob || request.cmtg_key || !request.prf_inputs.empty() ||
        !options.prf_inputs.empty() || options.large_blob_read || options.large_blob_write ||
        request.large_blob_extension_read || request.large_blob_extension_write ||
        request.cross_device_fallback_url || !request.user_presence_required) {
      FinishGet(GetStatus::kAuthenticatorResponseInvalid,{}); return;
    }
    allowed_.clear(); base::ListValue allowed;
    for (const auto& credential : request.allow_list) {
      allowed_.push_back(credential.id); allowed.Append(Encode(credential.id));
    }
    base::DictValue args; args.Set("rpId",rp_);args.Set("origin",origin_.Serialize());
    args.Set("clientDataHash",Encode(request.client_data_hash));
    args.Set("allowCredentials",std::move(allowed));
    // Pawl always supplies UP+UV; it never emulates a silent assertion.
    args.Set("userVerification","required");
    cancel_ = StartVaultPasskeyRequest(document_.AsRenderFrameHostIfValid(),origin_,1,std::move(args),
        base::BindOnce(&PawlAuthenticator::Asserted,weak_factory_.GetWeakPtr()));
  }
  bool ShouldCheckPlatformCredentialStatus() const override { return false; }
  void GetPlatformCredentialInfoForRequest(const device::CtapGetAssertionRequest&,
      const device::CtapGetAssertionOptions&,GetPlatformCredentialInfoForRequestCallback callback) override {
    // The current Pawl metadata has no userHandle. Do not manufacture resident
    // metadata or expose credentials to conditional autofill in this slice.
    std::move(callback).Run({},device::FidoRequestHandlerBase::RecognizedCredential::kUnknown);
  }
  void Cancel() override {
    weak_factory_.InvalidateWeakPtrs();
    make_callback_.Reset(); get_callback_.Reset(); allowed_.clear();
    if (cancel_) std::move(cancel_).Run();
  }
  std::string GetId() const override { return kPawlAuthenticatorId; }
  std::string GetDisplayName() const override { return "Pawl Vault"; }
  const device::AuthenticatorSupportedOptions& Options() const override {
    static const base::NoDestructor<device::AuthenticatorSupportedOptions> options([] {
      device::AuthenticatorSupportedOptions o;
      o.is_platform_device = device::AuthenticatorSupportedOptions::PlatformDevice::kYes;
      o.supports_resident_key = true;
      o.supports_user_presence = true;
      o.user_verification_availability = device::AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured;
      return o;
    }());
    return *options;
  }
  std::optional<device::FidoTransportProtocol> AuthenticatorTransport() const override {
    return device::FidoTransportProtocol::kInternal;
  }
  base::WeakPtr<device::FidoAuthenticator> GetWeakPtr() override { return weak_factory_.GetWeakPtr(); }
 private:
  bool Current() const {
    auto* frame = document_.AsRenderFrameHostIfValid();
    return frame && frame->IsActive() && frame->GetLastCommittedOrigin() == origin_ && current_ && current_.Run();
  }
  void FinishMake(MakeStatus code,std::optional<device::AuthenticatorMakeCredentialResponse> response) {
    cancel_.Reset(); auto callback = std::move(make_callback_);
    if (callback) std::move(callback).Run(code,std::move(response));
  }
  void FinishGet(GetStatus code,std::vector<device::AuthenticatorGetAssertionResponse> responses) {
    cancel_.Reset(); auto callback = std::move(get_callback_);
    if (callback) std::move(callback).Run(code,std::move(responses));
  }
  void Made(std::optional<std::string> json) {
    auto value = json ? base::JSONReader::ReadDict(*json,base::JSON_PARSE_RFC) : std::nullopt;
    auto encoded = value ? Decode(*value,"attestationObject") : std::nullopt;
    auto cbor = encoded ? cbor::Reader::Read(*encoded) : std::nullopt;
    auto attestation = cbor ? device::AttestationObject::Parse(*cbor) : std::nullopt;
    if (!Current() || !attestation) { FinishMake(MakeStatus::kUserConsentDenied,std::nullopt); return; }
    device::AuthenticatorMakeCredentialResponse response(device::FidoTransportProtocol::kInternal,std::move(*attestation));
    response.is_resident_key = true;
    // Chromium's handler performs its normal RP hash, flags and algorithm checks.
    FinishMake(MakeStatus::kSuccess,std::move(response));
  }
  void Asserted(std::optional<std::string> json) {
    auto value = json ? base::JSONReader::ReadDict(*json,base::JSON_PARSE_RFC) : std::nullopt;
    auto auth_bytes = value ? Decode(*value,"authenticatorData") : std::nullopt;
    auto signature = value ? Decode(*value,"signature") : std::nullopt;
    auto credential = value ? Decode(*value,"credentialId") : std::nullopt;
    auto auth = auth_bytes ? device::AuthenticatorData::DecodeAuthenticatorData(*auth_bytes) : std::nullopt;
    if (!Current() || !auth || !signature || signature->empty() || !credential || credential->empty() ||
        (!allowed_.empty() && std::ranges::find(allowed_,*credential) == allowed_.end())) {
      FinishGet(GetStatus::kUserConsentDenied,{}); return;
    }
    device::AuthenticatorGetAssertionResponse response(std::move(*auth),std::move(*signature),device::FidoTransportProtocol::kInternal);
    response.credential.emplace(device::CredentialType::kPublicKey,std::move(*credential));
    if (value->Find("userHandle") && !value->Find("userHandle")->is_none()) {
      auto user = Decode(*value,"userHandle");
      if (!user || user->empty() || user->size() > 64) { FinishGet(GetStatus::kUserConsentDenied,{}); return; }
      response.user_entity.emplace(std::move(*user));
    }
    // A resident assertion needs the real user ID returned by Pawl, never
    // synthetic resident metadata or a fallback to the current document.
    if (allowed_.empty() && !response.user_entity) {
      FinishGet(GetStatus::kAuthenticatorResponseInvalid,{}); return;
    }
    response.user_selected = true;
    std::vector<device::AuthenticatorGetAssertionResponse> responses;
    responses.push_back(std::move(response)); FinishGet(GetStatus::kSuccess,std::move(responses));
  }
  content::WeakDocumentPtr document_;
  const url::Origin origin_;
  const std::string rp_;
  const base::RepeatingCallback<bool()> current_;
  base::OnceClosure cancel_;
  MakeCredentialCallback make_callback_;
  GetAssertionCallback get_callback_;
  std::vector<std::vector<uint8_t>> allowed_;
  base::WeakPtrFactory<PawlAuthenticator> weak_factory_{this};
};
class PawlDiscovery final : public device::FidoDiscoveryBase {
 public:
  PawlDiscovery(content::RenderFrameHost* frame,const url::Origin& origin,const std::string& rp,base::RepeatingCallback<bool()> current)
      : FidoDiscoveryBase(device::FidoTransportProtocol::kInternal), authenticator_(frame,origin,rp,std::move(current)) {}
  void Start() override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<PawlDiscovery> self) {
          if (self && self->observer()) self->observer()->DiscoveryStarted(self.get(),true,{&self->authenticator_});
        },weak_factory_.GetWeakPtr()));
  }
  void Stop() override { weak_factory_.InvalidateWeakPtrs();authenticator_.Cancel(); }
 private:
  PawlAuthenticator authenticator_;
  base::WeakPtrFactory<PawlDiscovery> weak_factory_{this};
};
}  // namespace
bool IsVaultPasskeyAvailable(content::RenderFrameHost* frame) {
  auto current = VaultPasskeyContext(frame);
  return current && current.Run();
}
std::unique_ptr<device::FidoDiscoveryBase> CreateVaultPasskeyDiscovery(
    content::RenderFrameHost* frame,const url::Origin& origin,const std::string& rp) {
  auto current = VaultPasskeyContext(frame);
  if (!frame || !frame->IsActive() || origin.opaque() ||
      frame->GetLastCommittedOrigin() != origin ||
      !current || !current.Run()) return nullptr;
  return std::make_unique<PawlDiscovery>(frame,origin,rp,std::move(current));
}
}  // namespace barc
