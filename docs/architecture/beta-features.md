# Beta features

A new feature can ship switched off for everybody except the members who
switched on beta at `/settings/beta`. `Vutuv.Beta` owns all of it.

## Who gets a beta feature

Every member has one switch, `users.beta?`, off by default. When it is on,
they get every beta feature; when it is off, none. It works the same for
every account, admins included: nobody gets a beta feature for who they are.
Visitors who are not signed in never get one, so public pages and their
agent-format siblings stay the same for everyone.

The page is always on the settings hub, even when nothing is in beta, so a
member can sign up for what comes next. Below the switch it lists what is in
beta right now and since when, so a feature that has sat there for months is
noticed.

## Adding one

1. Add a `%Vutuv.Beta.Feature{}` to `@registry` in `lib/vutuv/beta.ex`: a
   key, the day it went into beta, and a title and description wrapped in
   `gettext_noop/1`.
2. Branch with `Vutuv.Beta.enabled?(user, :key)` wherever the new behaviour
   differs. In a LiveView pass the current user, never a bare id.
3. Test both sides: one member with beta on, one without.

`enabled?/2` raises for a key the registry does not know, so a typo fails the
suite instead of answering `false` in production.

## Ending one

When the feature graduates, delete its registry entry and every `enabled?`
call, and keep the new branch. When it is dropped, do the same and keep the
old branch. The members' switch stays as it is.

## Other installations

Nothing to configure. An operator cannot switch a beta feature on for
everybody; that is what graduating it in a release does.
