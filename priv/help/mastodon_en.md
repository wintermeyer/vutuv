# Using a Mastodon app

You can read and write here from an app built for Mastodon — Ivory, Tusky, Ice
Cubes, Mona, Elk and the rest. Nothing has to be installed on your phone beyond
the app itself, and you keep your ordinary account: the app signs in to it, the
same way any other app you connect does.

This is off until you turn it on.

## Turning it on

Open **Settings → Apps & API** and switch on *Allow Mastodon-compatible apps*.
Until you do, an app can complete the sign-in and then be refused by every
request after it, which looks like a broken app rather than a switch you have
not flipped.

Switching it off again takes effect immediately, including for apps you already
signed in from. Nothing on your profile changes either way.

## The address to type

When the app asks which server you are on, type:

```
{{host}}
```

That is all. Do not add `https://`, a path, or an `@`. Your account is then
`@yourusername@{{host}}` — that is the address to give somebody who wants to
follow you from another server.

The app will open a browser page here, ask you to sign in if you are not
already, and show you exactly what it wants to do. Approve it and the browser
hands you back to the app.

## Writing as a page

If you are in the Redaktion of an organization page, the approval screen offers
that page as a second identity. Pick it and everything the app posts is the
page's, not yours — the same as switching to the page on the website. Whoever
was signed in is still recorded behind the scenes, so the team can always tell
who wrote what.

An app signed in as a page cannot block anyone: blocking is between two people
and a page is not one.

## What works

* Your feed, the public timeline of this installation, and hashtag timelines
* Writing, editing and deleting posts, including photos
* Likes, reshares, bookmarks and replies, with the counts you see on the website
* Notifications, including push notifications while the app is closed
* Following, unfollowing, muting and blocking — members, pages, and accounts on
  other servers
* Searching for people, posts and topics
* Your saved and liked lists, your followers and who you follow

## What is different here

vutuv is not a Mastodon server, so a few things an app offers will not do what
you expect:

* **Posts are public.** The app's audience picker has no equivalent here — you
  narrow who may read a post on the website, not in the app.
* **No polls, no custom emoji, no scheduled posts.** An app that offers them
  will get an empty answer.
* **Direct messages are not Mastodon messages.** vutuv's messages are their own
  thing and stay on the website.
* **Follow requests do not exist.** A follow here takes effect at once.

## If something does not work

Check the switch first, then the address — those two account for almost every
failure. If an app signed in months ago and has stopped working, disconnect it
under **Settings → Apps & API → Connected apps** and sign in again.
