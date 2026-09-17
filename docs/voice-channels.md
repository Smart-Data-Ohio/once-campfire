# Persistent voice channels

A voice channel is a room with a standing huddle: members join and leave at
will, and nobody has to start a call. Each channel shows who is currently in
the call from the sidebar and the room header, and carries its own text chat
with durable history.

## Membership

Voice channels are a room type (`Rooms::Voice`) with closed-room membership:
explicit members chosen by an administrator or the creator, managed through
the same members UI as closed rooms. Voice rooms keep their type: unlike open
and closed rooms, they never convert to or from another type. Mention
notifications are the default.

## Text chat

The room page is the ordinary room page — messages, composer, threads — with
the voice presence and join controls in the header. People who are not in the
call read and write the same history as people who are.

## Presence

Who is in the voice channel is derived server-side from active `HuddleGrant`s
the gateway has seen within the last 20 seconds (`HuddleGrant.in_call`, the
same liveness signal DM ringing uses). Members can read it as JSON from
`GET /rooms/:room_id/huddle/participants` (`[{ id, name, avatar_url }]`), and
it renders as an avatar stack in the sidebar row and in the room header.

The stacks refresh over Turbo Streams when a grant is issued, revoked, or
first seen in the call. Grants that quietly expire — leaving the call does not
revoke the session's grant — fall off through a 15-second browser refresh,
which is the only polling in the feature. On phones the header stack shows at
most three avatars plus the count, yields its width before the room name
shrinks, and steps aside entirely below 360px.

## Joining and leaving

The room header button reads **Join voice** and **Leave voice**. Joining uses
the same `huddle:join` event and huddle panel as every other room, so audio,
screen share, camera, device controls, and reconnect behave identically.
Leaving goes through the panel's own Leave control. Voice rooms never create
invitations, ringing, or missed-call items.

## Sidebar

Voice channels list under their own **Voice** section below the channels list,
ordered by name. Each row shows the live participant count and up to three
avatars, with a subtle live treatment while anyone is in the call.

## Access removal

Removing a member, deleting the room, or deactivating the user ends their
voice session through the existing huddle revocation path, and they disappear
from the participant list. Removal also drops the member's sidebar row and
header stack over their existing rooms stream, and the presence poll treats
its 404 as the end of membership: it stops, clears, and never retries.

## Limits

This slice sets no concurrency cap. The desired voice concurrency is still an
open decision (see the roadmap), to be settled with load testing before
capacity expectations are set.
