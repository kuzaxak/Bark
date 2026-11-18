# Tasks

## 1. Define and implement the engine outcome

- [ ] 1.1 Add versioned size-checked request, result and prompt records to the SDK. Verify C and Swift import, export coverage and rejection of unsupported versions.
- [ ] 1.2 Complete each request from the settled physical window, including nested selection, refusal and teardown. Cover each outcome and empty selection in Chromium browser tests.
- [ ] 1.3 Record outgoing prompt dispositions with their originating documents. Check returning to a parked permission request, release on document destruction, refusal by a modal interaction and cancellation after a chooser loses its callback.

## 2. Consume the outcome in the shell

- [ ] 2.1 Route space selection from the sidebar, keyboard and palette through the same request. Prove that an obsolete async client creation or unsolicited discovery callback cannot overwrite the newer selection.
- [ ] 2.2 Update the sidebar and command target from the outcome. Test tabs in two profile spaces, two spaces sharing a client, a split's focused pane, an empty space and another open window.
- [ ] 2.3 Package the matching SDK and runtime. Verify the engine pin, exports, codesign checks and rollback by launching the earlier matched pair with a disposable profile.

## 3. Verify the integrated interaction

- [ ] 3.1 Walk a signed candidate using duplicate site titles and a pending Work location request. Switch by mouse and keyboard, verify the destination of the next input, then deny the request on its source document. Capture wrong-profile actions and focus loss.
- [ ] 3.2 Measure process launch to first observed successful input and selection to input on a parked page. Record hardware, app and engine revision, profile/cache condition and trial count.
