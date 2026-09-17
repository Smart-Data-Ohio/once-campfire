# Stage channels

A stage channel is a room with a standing huddle where a few members speak
and everyone else listens. Hosts run the stage, speakers publish audio and
video, and listeners subscribe only. Each channel shows who is currently in
the call from the sidebar and the room header, and carries its own text chat
with durable history.

Stage channels reuse the voice channel's presence, sidebar, header, and text
chat wholesale; see [voice channels](voice-channels.md) for those. This
document covers only what is stage-specific: roles, enforcement, and hand
raising.

## Membership and roles

Stage channels are a room type (`Rooms::Stage`) with closed-room membership:
explicit members chosen by an administrator or the creator, managed through
the same members UI as closed rooms. Stage rooms keep their type: like voice
rooms, they never convert to or from another type. Mention notifications are
the default.

Every stage membership has a role (`listener`, `speaker`, or `host`) and an
optional raised-hand timestamp. Non-stage rooms leave both columns nil. The
room creator becomes the first host; members added later start as listeners.
Administrators and hosts can change any member's role from the stage panel,
including their own, except that the last host cannot be demoted.

Administrators manage through membership like everyone else: an administrator
who is not a member of the room gets the same 404 as any other non-member on
the role and hand endpoints.

## Joining and listening

The room header button reads **Join stage** and **Leave stage**. Joining uses
the same `huddle:join` event and huddle panel as every other room. A listener
joins subscribe-only: the microphone, camera, and screen-share controls stay
hidden and the panel shows a "You are listening" note instead. Hosts and
speakers get the full panel. The join control carries a server-rendered hint
from the viewer's stage role: a listener's hint skips the device prejoin
check and any microphone acquisition and connects directly, while the token
remains the authority for publishing after connect. Voice and DM joins pass
no hint and behave as before.

Stage rooms list under the existing **Voice** section in the sidebar with a
stage glyph. They never create invitations, ringing, or missed-call items.

## Enforcement

Listener silence is enforced by the LiveKit token and by grant revocation,
not by hidden buttons.

- The join token carries `canPublish: false` and empty publish sources for
  listeners, and `canPublish: true` for hosts and speakers. Voice, DM, and
  channel tokens are unchanged.
- Each stage grant records the role it was issued for. The gateway's
  per-second authorization check revokes any grant whose issued role no
  longer matches the membership's current role.
- A role change revokes the member's active grants in the same transaction
  as the role change, reusing the existing revocation path so the gateway
  removes the participant. The affected member's browser then rejoins with a
  fresh token for the new role; LiveKit permissions are never updated in
  place.

To silence a speaker, a host moves them to the audience. There is no
per-speaker mute: demotion revokes the speaker's grant within the same
transaction, and the gateway removes them from the call.

## Hand raising

Listeners raise a hand from the stage panel; speakers and hosts have no hand
to raise. Hosts see raised hands first in the Listeners group, oldest first,
each with **Invite to speak** and **Lower hand**. Inviting promotes the
listener to speaker and clears the hand; lowering clears it without
promoting. Any role change clears the hand.

`POST /rooms/:room_id/stage/hand` raises the current member's hand and
`DELETE /rooms/:room_id/stage/hand` clears it. The DELETE endpoint also
accepts a `membership_id` parameter so a host or administrator can lower
another member's hand. `PATCH /rooms/:room_id/stage/roles/:membership_id`
changes a role; hosts and administrators only.

After a role change, a per-viewer roster is broadcast to every member's own
rooms stream — host action forms render only for hosts and administrators —
and a personalized panel is broadcast to the affected member's stream. That
replacement carries a rejoin trigger, and a second rejoin event is appended
to a persistent target inside the member's huddle panel, which exists on
every page unlike the stage panel: the huddle panel leaves and rejoins the
same room with a fresh token, skipping the prejoin check.

## Moderation

Removing a member from the stage uses the existing members UI, which already
ends their session and drops their sidebar row and header stack. An edit that
would remove the last host while members remain is rejected with 422 and an
inline error naming the host to replace first; emptying the room entirely
stays allowed. Role changes are the only stage moderation tool: there is no
separate mute, kick, or ban.

## Deliberately not included

Recording, streaming to an external audience, and per-speaker mute are not
part of stage channels. Streaming remains open on the roadmap; a host who
needs someone silent today moves them to the audience.
