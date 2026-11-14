# Sieve Script Deletion Design

**Date:** 2026-11-14

## Intent

Let the user permanently delete the selected server-side Sieve script from the SievePilot popover. If the script is active, SievePilot will deactivate it first, as explicitly selected by the user.

## Goals

- Add a destructive **Delete Script** action for the selected script.
- Name the script in a confirmation prompt.
- Warn that deleting an active script first deactivates it and leaves the account with no active Sieve script or active mail rules.
- Re-check server state immediately before mutation rather than trusting the displayed snapshot.
- Verify and display server state after deletion.
- Treat ambiguous network/protocol outcomes as unknown rather than claiming success.

## Non-goals

- Choosing or activating a replacement script.
- Backing up, restoring, or undoing deleted scripts.
- Automatically rolling back deactivation if deletion fails.
- Pruning old SievePilot-generated script versions automatically.

## Constraints and safety behavior

Deletion is permanent. The confirmation must distinguish active-script deletion from inactive-script deletion. Controls are disabled while the operation runs.

The service performs the mutation in one authenticated session. It first lists scripts to confirm the selected name still exists and determine its current active state. If active, it sends `SETACTIVE ""`, then sends `DELETESCRIPT` for the selected name. It lists scripts again and reads the remaining active script, if any, to build a verified snapshot.

If an ambiguous transport or protocol failure occurs after either mutation command, SievePilot reports an uncertain outcome and requires Refresh instead of asserting success. If deactivation succeeds but deletion is definitely rejected, the script remains stored but inactive; the error explains that no script is active.

After verified deletion, the model clears the deleted selection and uses the returned snapshot to update the list and out-of-office status.

## Approaches considered

1. **Delete inactive scripts only:** safest and simplest, but does not satisfy the requested ability to delete an active script.
2. **Deactivate and delete:** selected approach. It directly supports active deletion while clearly warning that mail rules will be left inactive.
3. **Require a replacement active script:** preserves active mail rules but adds a selection flow and behavior the user did not request.

## Testing

- Core service tests cover inactive deletion, active deactivation followed by deletion, stale/missing selection, definite rejection after deactivation, ambiguous outcomes, and verified post-delete snapshots.
- App-model tests cover operation state, successful selection clearing, verified state updates, and user-facing failure/unknown messages.
- View behavior is covered through model-facing state and confirmation/action wiring where practical in the existing test structure.
