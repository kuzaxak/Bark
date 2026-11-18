# Space switch outcome design

## Context

A physical host groups logical browser clients. Each client owns its own tab strip and profile. Swift owns the space IDs and sidebar tree. The discovery snapshot exposes the physical group, selected client and active tab, but a revision can cover several causes. A boolean from a selection call cannot distinguish refusal, reentrant selection and destruction.

## Decisions

1. Swift resolves a destination space to its logical client and requested tab or empty selection. It gives the request an identity scoped to the invoking window. When client creation is asynchronous, a newer intent or window teardown invalidates the older request before selection. Preserve the distinction between two spaces that share one client and between split panes that belong to different clients.
2. Chromium settles the selection on its UI thread. After synchronous activation and selection callbacks unwind, it captures the final owner once. The result contains the request identity, physical group, resulting client and focused tab or empty selection. It distinguishes applied, superseded, refused and closed. A subsequent independent selection is a new event. A completion for an older intent cannot overwrite a newer one.
3. Report each affected outgoing interaction with its originating document and disposition. Permission prompts can be hidden pending return, retained visibly on refusal, or retired by cancellation or teardown. Chromium remains responsible for dismissing the native surface and delivering the answer. Capturing the state after callbacks prevents a request to Home from being described as successful after Research won. An upload panel with a consumed callback reports cancellation. Keeping a live macOS upload panel across switches requires a separate product and engine decision.
4. Swift consumes the result in one model update shared by the sidebar and command routing. Resolve a final pane by owning client and tab. A refused request retains the previous space, including its last valid pane. A closed or unresolvable owner cannot redirect a command to another window. Use discovery for startup, recovery, independently created pages and unsolicited engine selection changes. Tests exercise reconciliation during a pending request to prevent double application.
5. Append a versioned bridge entry with size-checked C records. The outcome and any variable-length prompt records are immutable for the duration of delivery, and Swift copies them before returning. No engine objects or addresses cross the boundary. Ship the Swift consumer with a matching SDK and engine pin. An existing app retains its current paired engine.

## Rollout and verification

Exercise native reentrancy, owner teardown and an empty space in the Chromium browser tests. Exercise overlapping asynchronous requests and two spaces in one profile in the Swift host tests. Run the signed two-profile walk with a duplicate site, capture the first command after switching, and answer the original location request on return. Verify bridge exports, pin and architecture during packaging. A rollback restores the previous application and engine together.
