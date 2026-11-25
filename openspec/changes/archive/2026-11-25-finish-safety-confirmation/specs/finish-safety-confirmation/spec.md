## ADDED Requirements

### Requirement: Closed gate keeps today's finish flow
When the backend confirmation gate is closed, `POST /api/orders/{id}/finish` returns `completed=true` (or omits the field) and both apps MUST behave exactly as before this change.

#### Scenario: Volunteer finishes with the gate closed
- **WHEN** the volunteer long-presses finish and the response has `completed=true` or no `completed` key
- **THEN** the page follows the existing submit-and-confirm path to `COMPLETED`

### Requirement: Volunteer finish request waits for the runner
When the response has `completed=false`, the volunteer app MUST NOT enter the status-confirmation path. It MUST show and speak that the runner was asked to confirm, with the earliest unilateral finish time taken from the backend `unilateralFinishOpensAt`.

#### Scenario: First press with the gate open
- **WHEN** finish returns `completed=false` and `unilateralFinishOpensAt`
- **THEN** the running page shows a notice with that clock time and the speech says the same
- **AND** the finish button stays usable

#### Scenario: Press before the unilateral time
- **WHEN** finish returns 409 `BLIND_SAFETY_CONFIRMATION_PENDING`
- **THEN** the app speaks the backend message

#### Scenario: Press after the unilateral time
- **WHEN** finish returns `completed=true`
- **THEN** the order completes through the existing path

### Requirement: Runner confirms safety from the running page
While the order is `IN_PROGRESS` and `finishRequestedAt` is non-null, the runner running page MUST show the button 「我已在安全的地方，结束陪跑」 as the first card under the title, MUST move VoiceOver focus to it when it appears, and MUST call `POST /api/orders/{id}/confirm-safe`.

#### Scenario: Request arrives in real time
- **WHEN** `FINISH_SAFETY_CONFIRM_REQUESTED` arrives
- **THEN** it is presented and spoken as a safety notice on any screen, and the order is refreshed

#### Scenario: Cold start with a pending request
- **WHEN** the app restarts and the order detail has `finishRequestedAt`
- **THEN** the button shows and the status announcement mentions the request

#### Scenario: Request expires
- **WHEN** `finishRequestedAt` returns to null
- **THEN** both apps return to the normal running page without the button or the notice

### Requirement: Post-finish SOS stays on the order
After `COMPLETED` and before the backend `postFinishSosUntil`, the runner SOS MUST go to the cloud with this order's ID. The volunteer SOS MUST stay `IN_PROGRESS`-only.

#### Scenario: Runner presses help just after finishing
- **WHEN** the order is `COMPLETED` and now is before `postFinishSosUntil`
- **THEN** `BlindHomeSOSMode.resolve` returns cloud and `EmergencyCoordinator.trigger` sends with the order ID

#### Scenario: Window has passed
- **WHEN** now is at or after `postFinishSosUntil`, or the field is null
- **THEN** the runner entry falls back to local dialing as before
