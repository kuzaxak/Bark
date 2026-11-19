#ifndef BARC_CHROMIUM_BRIDGE_FUNCTIONS_H_
#define BARC_CHROMIUM_BRIDGE_FUNCTIONS_H_

#include "bark/bridge/barc_bridge_api.h"

// The engine's definitions of the table's members, in table order. Their
// documentation is on the members in barc_bridge_api.h. Engine code and browser
// tests call them by name; the app reaches them only through the table.
#ifdef __cplusplus
extern "C" {
#endif
const char* barc_chromium_version(void);
void barc_set_runtime_ready_callback(BarcRuntimeReadyCallback callback, void* user_data);
void barc_set_runtime_close_callback(BarcRuntimeCloseCallback callback, void* user_data);
void barc_set_runtime_window_request_callback(BarcWindowRequestCallback callback, void* user_data);
void barc_set_runtime_browser_target_callback(BarcBrowserTargetCallback callback, void* user_data);
void barc_runtime_complete_startup(int32_t window);
void barc_profile_open_window(const char* profile_uuid, barc_profile_destination destination, barc_profile_window_callback callback, void* user_data);
void barc_profile_open_in_native_window(int32_t native_owner, const char* profile_uuid, barc_profile_destination destination, barc_profile_window_callback callback, void* user_data);
void barc_private_session_open_window(barc_profile_window_callback callback, void* user_data);
size_t barc_window_profile_uuid(int32_t window, char* buffer, size_t capacity);
size_t barc_window_private_session_uuid(int32_t window, char* buffer, size_t capacity);
int barc_profile_delete_cancel_ack(const char* target_uuid, const char* survivor_uuid);
void barc_profile_delete_kept(const char* target_uuid, const char* survivor_uuid, int32_t reconcile_only, barc_profile_delete_callback callback, void* user_data);
void barc_profile_prepare_reassignment(const char* target_uuid, const char* survivor_uuid, int32_t reconcile_only, barc_profile_delete_callback callback, void* user_data);
void barc_profile_continue_deletion(const char* target_uuid, const char* survivor_uuid, barc_profile_delete_callback callback, void* user_data);
void barc_profile_search_state(const char* uuid, int32_t window, int32_t is_private, const char* seed, const char* selection, int32_t include_choices, barc_search_callback callback, void* context);
uint64_t barc_profile_live_get(const char* uuid, int32_t source, const char* argument, barc_live_callback callback, void* context);
void barc_profile_live_cancel(uint64_t token);
int32_t barc_window_new_peer(int32_t source_window);
int32_t barc_window_new_peer_in_native_window(int32_t source_window, int32_t physical_owner);
int barc_window_close(int32_t window);
int barc_window_set_app_lifetime(int32_t window);
int barc_window_set_page_hidden(int32_t window, int hidden);
size_t barc_window_tab_count(int32_t window);
int32_t barc_window_tab_at(int32_t window, size_t index);
int barc_window_select(int32_t window);
int barc_window_show(int32_t window);
int barc_window_attach_native_shell(int32_t window, void* native_view);
int barc_window_set_native_header(int32_t window, void* expected_sidebar, void* expected_header, void* replacement_header, int32_t height);
int barc_window_native_shell_is_owned(int32_t window, void* expected_view);
int barc_window_detach_native_shell_if_owned(int32_t window, void* expected_view);
int32_t barc_tab_create(int32_t window, const char* url, int foreground);
int barc_tab_select(int32_t window, int32_t tab);
int barc_tab_search(int32_t window, int32_t tab, const char* query, const char* kagi_session_token);
int barc_tab_navigate(int32_t window, int32_t tab, const char* url);
int barc_tab_close(int32_t window, int32_t tab);
int barc_tab_transfer(int32_t source_window, int32_t tab, int32_t destination_window);
int barc_tab_transfer_with_admission(int32_t source_window, int32_t tab, int32_t destination_window, BarcTransferAdmission admission, void* context);
size_t barc_tab_copy_launch_space(int32_t window, int32_t tab, char* output, size_t capacity);
int barc_tab_application_pending(int32_t window, int32_t tab);
int barc_tab_execute_command(int32_t window, int32_t tab, int32_t command);
int barc_tab_set_muted(int32_t window, int32_t tab, int muted);
size_t barc_tab_copy_title(int32_t window, int32_t tab, char* buffer, size_t capacity);
size_t barc_tab_copy_history(int32_t window, int32_t tab, int32_t direction, char* output, size_t capacity);
int barc_tab_go_to_history_entry(int32_t window, int32_t tab, int32_t entry);
int barc_tab_go_back(int32_t window, int32_t tab);
int barc_tab_go_forward(int32_t window, int32_t tab);
int barc_tab_reload(int32_t window, int32_t tab);
int barc_tab_stop(int32_t window, int32_t tab);
int barc_tab_media_action(int32_t window, int32_t tab, int32_t action);
uint64_t barc_tab_observe(int32_t window, int32_t tab, BarcTabCallback callback, void* context);
void barc_tab_unobserve(uint64_t observation);
int barc_tab_close_selecting(uint64_t observation, int32_t successor);
int barc_tab_enable_peek(uint64_t observation, int enabled);
int barc_tab_observe_media(uint64_t observation, BarcMediaCallback callback);
int barc_tab_capture_thumbnail(uint64_t observation, uint64_t request, BarcTabThumbnailCallback callback);
int barc_tab_capture_screenshot(uint64_t observation, uint64_t request, int32_t max_width, BarcTabThumbnailCallback callback);
int barc_tab_cancel_capture(uint64_t observation, uint64_t request);
int barc_tab_download_file(uint64_t observation, uint64_t request, const char* url, const char* directory, BarcFileCallback callback);
int barc_tab_cancel_file(uint64_t observation, uint64_t request);
int barc_tab_clear_site_data(uint64_t observation, uint64_t request, int32_t action, BarcSiteDataCallback callback);
int barc_tab_set_user_css(uint64_t observation, uint64_t request, const char* committed_url, const char* css, BarcStyleCallback callback);
int barc_tab_translate(uint64_t observation, uint64_t generation, uint64_t request, int32_t operation, const char* pairs, BarcTranslationCallback callback);
int barc_tab_evaluate_script(uint64_t observation, uint64_t request, int32_t mode, int32_t world, const char* source, BarcScriptCallback callback);
int barc_tab_cancel_script(uint64_t observation, uint64_t request);
int barc_tab_start_boost_picker(uint64_t observation, uint64_t request, BarcPickerCallback callback);
int barc_tab_cancel_boost_picker(uint64_t observation, uint64_t request);
int barc_tab_observe_vault(uint64_t observation, BarcVaultCallback callback);
int barc_tab_vault_focus_is_current(uint64_t observation, uint64_t focus);
int barc_tab_vault_field_is_current(uint64_t observation, uint64_t focus);
int barc_tab_cancel_vault_focus(uint64_t observation, uint64_t focus);
int barc_tab_fill_vault(uint64_t observation, uint64_t focus, const char* username, const char* secret);
int barc_tab_observe_vault_save(uint64_t observation, BarcVaultSaveCallback callback);
int barc_tab_vault_save_is_current(uint64_t observation, uint64_t submission);
int barc_tab_cancel_vault_save(uint64_t observation, uint64_t submission);
int barc_tab_observe_vault_passkeys(uint64_t observation, BarcVaultPasskeyCallback callback);
int barc_tab_vault_passkey_is_current(uint64_t observation, uint64_t request);
int barc_tab_complete_vault_passkey(uint64_t observation, uint64_t request, int32_t accepted, const char* result);
int barc_tab_create_peek(uint64_t source_observation, int32_t request, BarcTransferAdmission admission, void* context);
uint64_t barc_tab_present_peek(int32_t source_window, int32_t source_tab, int32_t peek_window, int32_t peek_tab, void* expected_sidebar, void* header, void* actions);
int barc_tab_hide_peek(int32_t source_window, int32_t source_tab, int32_t peek_window, int32_t peek_tab, uint64_t generation, void* expected_header, void* expected_actions);
int barc_tab_is_peek_presented(int32_t source_window, int32_t source_tab, int32_t peek_window, int32_t peek_tab, uint64_t generation, void* expected_header, void* expected_actions);
int barc_window_set_split(int32_t window, const BarcSplitLayout* layout);
int barc_window_get_split(int32_t window, int32_t member, BarcSplitLayout* layout);
int barc_window_clear_split(int32_t window, int32_t member, const BarcSplitLayout* expected);
uint64_t barc_downloads_observe(BarcDownloadCallback callback, void* context);
void barc_downloads_unobserve(uint64_t observation);
int barc_download_action(uint64_t observation, uint64_t manager, const char* guid, int32_t action);
size_t barc_download_copy_safe_target(uint64_t observation, uint64_t manager, const char* guid, char* buffer, size_t capacity);
int32_t barc_discovery_snapshot(BarcDiscoveryWindow* windows, size_t window_capacity, BarcDiscoveryTab* tabs, size_t tab_capacity, BarcDiscoverySnapshot* out_snapshot);
uint64_t barc_discovery_observe(BarcDiscoveryCallback callback, void* context);
void barc_discovery_unobserve(uint64_t observation);
int barc_window_discovery_state(int32_t window, BarcDiscoveryWindow* out_window);
int barc_window_admit_discovered(int32_t window, void* expected_native_view);
int barc_blocker_set_policy(int32_t policy, uint64_t required_source_generation, const char* const* allowed_domains, size_t count);
int barc_blocker_publish_rules(const uint8_t* bytes, size_t length, uint64_t source_generation, BarcBlockerCallback callback, void* context);
int barc_blocker_prepare(int32_t window, BarcBlockerCallback callback, void* context);
int barc_blocker_state(int32_t window, BarcBlockerState* out_state);
int barc_blocker_set_tab_policy(int32_t window, int32_t tab, int32_t oauth, const char* continued_host, uint64_t disabled_for_ms);
int barc_page_tweaks_publish(const uint8_t* json, size_t length);
int barc_window_set_root_view(int32_t window, void* root_view);
void* barc_tab_native_view(int32_t window, int32_t tab);
int barc_window_set_chrome(int32_t window, const BarcWindowChrome* chrome);
uint64_t barc_window_host_observe(int32_t window, BarcWindowHostCallback callback, void* context);
void barc_window_host_unobserve(uint64_t observation);
int barc_window_switch_space(const BarcSpaceSwitchRequest* request,
                             BarcSpaceSwitchCallback callback, void* context);
int barc_tab_list_extension_actions(int32_t window, int32_t tab,
                                    BarcExtensionActionCallback callback, void* context);
int barc_tab_set_extension_pinned(int32_t window, int32_t tab,
                                  const char* extension_id, int pinned);
int barc_tab_invoke_extension(int32_t window, int32_t tab, const char* extension_id);
int barc_tab_renderer_state(int32_t window, int32_t tab, int32_t* pid,
                            int32_t* document_visible);
#ifdef __cplusplus
}
#endif
#endif
