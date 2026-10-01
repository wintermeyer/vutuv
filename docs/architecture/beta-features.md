# Beta features

A new feature can ship switched off for everybody and be switched on by each
member who wants to try it, at `/settings/beta`. `Vutuv.Beta` owns all of it.

## Who gets a beta feature

Nobody gets one for who they are, admins included. A feature has an
audience, and the audience only decides who is **offered** it:

- `:members`: every signed-in member sees the checkbox.
- `:admins`: only admins see it (typically a change under `/admin`). An
  admin still has to tick it, and loses it the moment they lose the role.

Visitors who are not signed in never get a beta feature, so public pages and
their agent-format siblings stay the same for everyone.

The choice is stored in `users.beta_features`, an array of keys.
`/settings/beta` is listed on the settings hub only while the release offers
the member at least one feature.

## Adding one

1. Add a `%Vutuv.Beta.Feature{}` to `registry/0` in `lib/vutuv/beta.ex`: a
   key, the audience, the day it went into beta, and a translated title and
   description (the description is all a member reads before ticking it).
2. Branch with `Vutuv.Beta.enabled?(user, :key)` wherever the new behaviour
   differs. In a LiveView pass the current user, never a bare id.
3. Test both sides: one member with it on, one without.

`enabled?/2` raises for a key the registry does not know, so a typo fails the
suite instead of answering `false` in production.

## Ending one

When the feature graduates, delete its registry entry and every `enabled?`
call, and keep the new branch. When it is dropped, do the same and keep the
old branch. No migration is needed: keys of features that no longer exist
are ignored on read and dropped on the member's next save. The settings page
shows each feature's start date, so one that has sat in beta for months is
noticed.

## Other installations

Nothing to configure. An operator cannot switch a beta feature on for
everybody; that is what graduating it in a release does.
