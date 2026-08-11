# Maestro Workflow

Maestro coordinates bounded implementation and design work between the conducting Claude session and the performing Codex companion. This language describes the durable workflow concepts that must remain stable across hook and script implementations.

## Language

**Implementation run**:
A bounded sequence of Write turns and Verification transactions under one Lease interval. It ends with verified completion or a precise terminal state.
_Avoid_: Dispatch loop, retry loop

**Write turn**:
One write-capable Codex attempt within an Implementation run, from launch to terminal outcome. It does not own the surrounding Lease interval.
_Avoid_: Dispatch, job

**Cancellation fact**:
A caller-owned terminal record of why companion activity ended and whether a cancellation request was acknowledged, unconfirmed, not attempted, or observed. A Write turn pairs it with fail-closed Lease interval recovery; a Discussion turn uses it to classify retry behavior.
_Avoid_: Cancellation global, inferred cancellation

**Lease interval**:
The period during which one Implementation run has exclusive write authority over the repository. It ends only after safe release or explicit operator recovery.
_Avoid_: Lock lifetime, timeout window

**Verification transaction**:
A Codex completion claim evaluated against independent local proof. It either verifies the Implementation run or produces evidence for another Write turn.
_Avoid_: Test run, DONE check

**Discussion turn**:
One orchestrator transcript addition paired with one persisted read-only Codex reply. Transport retries remain inside the turn.
_Avoid_: Debate job, chat message
