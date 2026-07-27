# Experiments

Split tests on public copy. There is exactly one right now: the founder quote
at the top of the logged-out landing page.

Everything lives in `Vutuv.Experiments` (assignment, counters, the verdict),
`VutuvWeb.LandingExperiment` (the session and the three call sites) and the
read-only admin page at `/admin/experiments`.

## The design in one paragraph

A logged-out visitor arriving at `/` is given one of two variants at random.
The choice goes into the session the sign-up form already needs for its CSRF
token, so the test sets **no cookie of its own** and the headline does not
flicker when the page is reloaded. Three moments are then counted per variant:
the **view** (once per session, not per page load), the **signup** (the sign-up
form created an account) and the **confirmation** (that account entered its PIN
and became a real member). Because `Plug.Conn.configure_session(renew: true)`
rotates the session id but keeps its contents, the variant survives both the
registration POST and the PIN round trip, which is what makes the third counter
possible at all.

## What is stored

`experiment_stats`, one row per experiment, variant and **Berlin calendar day**,
holding three integers. No visitor, session id, address or user agent is
recorded, so there is nothing here that could identify anyone and nothing that
a privacy page has to promise about. That is deliberate: an A/B test is a
famously easy place to start keeping per-visitor records nobody asked for.

Counters are bumped with a single `Repo.insert_all` upsert against the
`[experiment, variant, day]` unique index, so two concurrent requests increment
rather than race.

## Reading the result

The admin page shows the per-variant conversion rates, but the **verdict** is
deliberately not computed from them. Crawlers that ignore cookies get a fresh
session per request and inflate the view counts; they inflate both arms alike,
so the rates are diluted while the comparison stays sound. The verdict
therefore tests the thing bot traffic cannot touch: how the sign-ups themselves
**split** between the two arms, against the 50/50 the random assignment
produces. Below `Vutuv.Experiments.min_signups/0` outcomes the page refuses to
name a winner at all, because reading a lead out of the first handful of
registrations is the classic way to ship the worse headline with great
confidence.

`p` is reported as a percentage in plain language ("a lead this size turns up
by chance 3.4 % of the time") rather than as a statistic, and the maths is a
normal approximation with a continuity correction (`Vutuv.Experiments.p_value/2`,
with an Abramowitz & Stegun `erf` since Erlang's `:math` has none). Exact
enough from thirty outcomes, and no dependency for one admin page.

Two verdicts are shown, because they can disagree and the disagreement is the
interesting part: a headline that pulls people into the sign-up form but not
through the PIN has won nothing.

## Ending a test

Pick the winner and delete the loser from `VutuvWeb.PageHTML.founder_quote/1`,
then drop the variant from `Vutuv.Experiments`. That is a deploy on purpose:
a headline should not be switchable from a dashboard by a mis-click, and the
`experiment_stats` rows stay as the record of why the surviving copy won.

## Other installations

`config :vutuv, :landing_headline_experiment` (env override
`LANDING_HEADLINE_EXPERIMENT=false`) turns the whole thing off: every visitor
gets `Vutuv.Experiments.default_landing_variant/0` and nothing is counted. An
installation that has replaced the landing copy, or simply does not want its
start page to vary, sets it to false and never thinks about this subsystem
again.
