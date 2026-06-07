# Production cutover: UUID v7 ids

One-time steps for the first production deploy that includes the
`convert_ids_to_uuid_v7` migration (every PK/FK becomes a UUID v7; the dead
legacy skill tables are dropped first). The migration runs in one
transaction and aborts itself if any parent/child link would be lost, but
its `down/0` raises — **the dump below is the only rollback**.

## Before the deploy (manual, on the server)

- [ ] `pg_dump -Fc -d vutuv3_prod -f ~/vutuv3_prod_pre_uuid_$(date +%Y%m%d).dump`
  immediately before the deploy. Keep it until the cutover is verified.

## After the deploy

- [ ] Migration log shows `== Migrated … convert_ids_to_uuid_v7` (a raised
  `UUID conversion would lose …` means it rolled back — investigate, the data
  is untouched).
- [ ] All pre-cutover sessions are invalid by design (the cookie stores an
  integer user id): spot-check that a stale session renders pages logged-out
  without a 500 and that a fresh PIN login works.
- [ ] Spot-check a user profile: posts, followers, tags and emails still
  hang together (relationships were re-keyed, not re-created).

# Production cutover: AVIF images + private originals

One-time steps for the first production deploy that includes commit
`a782e4f` (AVIF-only served images, private `originals/` tree). Work through
this top to bottom; the last step deletes this file.

## 1. Before the deploy (manual, on the server)

- [ ] Edit the nginx vhost: the internal post-images location must accept
  both extensions during the transition:

  ```nginx
  location ~ ^/internal_post_images/(?<token>[A-Za-z0-9_-]+)/(?<version>thumb|feed|large)\.(?<fmt>avif|webp)$ {
      internal;
      alias /srv/legacy-vutuv/post_images/$token/$version.$fmt;
  }
  ```

- [ ] Confirm **no** nginx `location`/`alias` touches
  `/srv/legacy-vutuv/originals/` (uploaded originals are never served).
- [ ] `nginx -t && systemctl reload nginx`

## 2. Deploy

- [ ] Deploy as usual (push to `main`). `scripts/deploy.sh` runs
  `Vutuv.Release.regenerate_images()` after the restart; not-yet-converted
  images keep serving through the transitional fallback in the meantime.
  Optional rehearsal first:
  `bin/vutuv eval "Vutuv.Release.regenerate_images(dry_run: true)"`

## 3. Verify after the run

- [ ] Read the regeneration summary in the deploy log. Expect numbers in the
  ballpark of the dev clone: ~1,772 avatars / 1,816 screenshots, **11
  skipped** (original missing, files left untouched, keep serving via
  fallback) and **1 failed** (user 12610, corrupt original). Hand-check the
  skipped/failed rows it lists.
- [ ] Expect the orphan pass to move ~208 unclaimed originals (deleted
  users) out of the public trees.
- [ ] Spot-check in a browser: an avatar and a cover load as
  `…_thumb.avif` / `…_wide.avif` with `content-type: image/avif`; a post
  image loads via `/post_images/<token>/feed.avif`; an old post body with a
  literal `…/feed.webp` reference still renders; `/originals/...` is 404.
- [ ] vCard export still carries `PHOTO;ENCODING=b;TYPE=JPEG:`.

## 4. Follow-up cleanup commit (once a re-run reports only `unchanged`)

- [ ] Remove the transitional legacy fallbacks, all marked with a comment
  pointing at `Spec.legacy_exts/0`:
  - `Vutuv.Uploads.Spec.legacy_exts/0`
  - `served_filename`/`legacy_filename` fallbacks in `Vutuv.Avatar`,
    `Vutuv.Cover`, `Vutuv.Screenshot`
  - the `.webp` branch in `Vutuv.PostImageStore.version_filename/2`
  - the `"webp"` acceptance in `VutuvWeb.PostImageController.parse_version/1`
  - `Vutuv.Posts.PostImage.url_forms/2` (markdown then maps only the
    canonical URL)
- [ ] Narrow the nginx internal regex to `\.avif$` and update the README
  snippet to match.
- [ ] Delete this file.
