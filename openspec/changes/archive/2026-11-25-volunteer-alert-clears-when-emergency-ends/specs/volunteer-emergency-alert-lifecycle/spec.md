## ADDED Requirements

### Requirement: Volunteer alert follows the backend while it is shown
While the volunteer emergency alert (full screen or top bar) is shown, the app MUST ask `GET /api/emergency/active` at a fixed interval and MUST remove the alert when the response has no open event. When no alert is shown, the app MUST NOT poll.

#### Scenario: Emergency ends while the app stays open
- **WHEN** the alert is shown and the backend later reports no open event
- **THEN** the next poll removes the alert

#### Scenario: No alert
- **WHEN** no volunteer alert is shown
- **THEN** the app sends no `GET /api/emergency/active` request for this purpose

### Requirement: Alert clears when the volunteer leaves the order
When the alert's order moves to `CANCELLED`, `NO_VOLUNTEER`, `PENDING_MATCH` or `REMATCHING`, the app MUST remove the alert at once. When it moves to `COMPLETED`, the app MUST ask the backend at once instead of removing the alert locally, because the runner can still call for help until `sosWindowEndsAt`.

#### Scenario: Order cancelled during an alert
- **WHEN** a status update moves the alert's order to `CANCELLED`
- **THEN** the alert is removed without waiting for the next poll

#### Scenario: Order completed during an alert
- **WHEN** a status update moves the alert's order to `COMPLETED`
- **THEN** the app asks `GET /api/emergency/active` and keeps the alert if the event is still open

### Requirement: Removing the alert is announced
When the alert is removed while the volunteer is signed in, the app MUST speak one sentence saying the help alert was put away. It MUST NOT offer the volunteer a manual way to dismiss an open alert.

#### Scenario: Alert removed
- **WHEN** the alert disappears because the emergency ended or the volunteer left the order
- **THEN** the app speaks the alert-removed sentence once
