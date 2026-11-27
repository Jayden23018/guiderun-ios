## ADDED Requirements

### Requirement: The booking page tells the runner when no volunteer is near the start point
The client SHALL call `GET /api/orders/nearby-volunteers` with the current GCJ-02 start point when the booking page opens and when the start point changes. A selected place counts as changed when its id changes; the current location counts as changed after it moves at least 1 km. When `hasNearbyVolunteers` is false and `hint` is not blank, the client SHALL show a persistent card under the start-point heading with the title 「目前附近无志愿者」, the server `hint`, and a secondary button 「换个出发点」. The button SHALL be omitted when the saved-place list is full. The card SHALL NOT disable or block order submission.

#### Scenario: No volunteer nearby
- **WHEN** the response is `hasNearbyVolunteers: false` with a `hint`
- **THEN** the card SHALL be the first element after the start-point heading
- **AND** VoiceOver SHALL read it as one element: 「提示，目前附近无志愿者。<hint>」
- **AND** the client SHALL speak 「目前附近无志愿者。<hint>」 as soon as the result arrives, through both the App voice and VoiceOver

#### Scenario: The notice interrupts another sentence
- **WHEN** the result arrives while the entry announcement is still being spoken
- **THEN** the client SHALL speak the notice first, followed by an entry announcement built from the current selection
- **AND** any other interrupted sentence SHALL be repeated after the notice, except the notice of a previous start point

#### Scenario: Result is unknown
- **WHEN** there is no trusted coordinate, the request fails (including 404 and 429), or `hint` is null
- **THEN** no card SHALL be shown and no error SHALL be shown

#### Scenario: Picking the current default again on the add page
- **WHEN** this order uses a non-default place and the runner picks the existing default (or the current location) on the add page
- **THEN** the booking page SHALL use that pick

#### Scenario: Start point changes while a request is in flight
- **WHEN** the response belongs to a previous start point
- **THEN** the client SHALL ignore it
