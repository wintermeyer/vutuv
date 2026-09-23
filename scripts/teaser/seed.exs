# Builds (and resets) everything the teaser shows, in the local dev database only.
#
#   mix run --no-start scripts/teaser/seed.exs <lang> <out_dir>
#
# Idempotent: run it before every recording. It creates the fictional members
# (Miriam Kessler, Anna Berger, Jonas Keller, Lena Hoffmann), Miriam's profile,
# links, social accounts, her Stammtisch post with likes and Anna's reply, a
# clean chat, the fictional job postings, and dates two real news posts from
# the database copy to "20 minutes ago" so they head Miriam's feed. Everything
# comes from scripts/teaser/content.<lang>.json.
#
# Nothing here talks to the network: fediverse delivery, web push, screenshot
# capture and image moderation are switched off for this VM.
Application.put_env(:vutuv, :fediverse_enabled, false, persistent: true)
Application.put_env(:vutuv, :web_push_enabled, false, persistent: true)
Application.put_env(:vutuv, :moderate_images, false, persistent: true)
Application.put_env(:vutuv, :generate_screenshots, false, persistent: true)
Application.put_env(:vutuv, :fetch_code_stats, false, persistent: true)
Application.put_env(:phoenix, :serve_endpoints, false, persistent: true)
{:ok, _} = Application.ensure_all_started(:vutuv)

import Ecto.Query
alias Vutuv.{Repo, Accounts, Social, Tags, Posts, Chat, Jobs, UUIDv7}
alias Vutuv.Accounts.User
alias Vutuv.Profiles.{WorkExperience, Education, Language, Url, SocialMediaAccount}
alias Vutuv.Posts.Post
alias Vutuv.Jobs.JobPosting

[lang, out_dir] =
  case System.argv() do
    [l, o] -> [l, o]
    [l] -> [l, "_build/teaser/#{l}"]
    _ -> raise "usage: seed.exs <de|en> [out_dir]"
  end

here = Path.dirname(__ENV__.file)
assets = Path.expand("../../_build/teaser/assets", here)

contents =
  for f <- ["de", "en"],
      into: %{},
      do: {f, here |> Path.join("content.#{f}.json") |> File.read!() |> Jason.decode!()}

c = Map.fetch!(contents, lang)
File.mkdir_p!(out_dir)

dump = &Ecto.UUID.dump!/1
now = NaiveDateTime.utc_now(:second)
ago = fn minutes -> NaiveDateTime.add(now, -minutes * 60) end
log = fn msg -> IO.puts("SEED #{msg}") end

# ---------- members ----------
members = [
  {"miriam_kessler", "Miriam", "Kessler", "miriam.kessler@example.com"},
  {"anna_berger", "Anna", "Berger", "anna.berger@example.com"},
  {"jonas_keller", "Jonas", "Keller", "jonas.keller@example.com"},
  {"lena_hoffmann", "Lena", "Hoffmann", "lena.hoffmann@example.com"}
]

user = fn username -> Repo.one!(from(u in User, where: u.username == ^username)) end

for {username, first, last, email} <- members do
  unless Repo.exists?(from(u in User, where: u.username == ^username)) do
    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("accept-language", lang)

    {:ok, u} =
      Accounts.register_user(conn, %{
        "first_name" => first,
        "last_name" => last,
        "emails" => %{"0" => %{"value" => email}},
        "tag_list" => "Elixir, Phoenix Framework, Open Source"
      })

    if u.username != username, do: raise("#{email} became @#{u.username}, expected @#{username}")
    log.("created @#{username}")
  end

  # confirmed (chat and jobs need it), indexed, and speaking the video's language
  Repo.query!(
    ~s|update users set "email_confirmed?" = true, "noindex?" = false, locale = $1, inserted_at = least(inserted_at, now() - interval '60 days') where username = $2|,
    [lang, username]
  )
end

miriam = user.("miriam_kessler")
anna = user.("anna_berger")
m = c["miriam"]

# ---------- Miriam's profile ----------
{:ok, miriam} = Accounts.update_user(miriam, %{headline: m["headline"]})

Repo.delete_all(from(t in Vutuv.Tags.UserTag, where: t.user_id == ^miriam.id))

for name <- String.split(m["tags"], ",", trim: true),
    do: Tags.add_user_tag(miriam, String.trim(name))

Repo.delete_all(from(w in WorkExperience, where: w.user_id == ^miriam.id))
Repo.delete_all(from(e in Education, where: e.user_id == ^miriam.id))
Repo.delete_all(from(l in Language, where: l.user_id == ^miriam.id))

for job <- m["cv"] do
  [sm, sy] = job["from"]
  [em, ey] = job["to"] || [nil, nil]

  %WorkExperience{user_id: miriam.id}
  |> WorkExperience.changeset(%{
    title: job["title"],
    organization: job["org"],
    kind: job["kind"],
    description: job["desc"],
    start_month: sm,
    start_year: sy,
    end_month: em,
    end_year: ey
  })
  |> Repo.insert!()
end

e = m["education"]
[esm, esy] = e["from"]
[eem, eey] = e["to"]

%Education{user_id: miriam.id}
|> Education.changeset(%{
  school: e["school"],
  degree: e["degree"],
  field_of_study: e["field"],
  kind: "university",
  start_month: esm,
  start_year: esy,
  end_month: eem,
  end_year: eey
})
|> Repo.insert!()

for {{code, level}, pos} <- Enum.with_index([{"de", "native"}, {"en", "c1"}, {"es", "b1"}]) do
  %Language{user_id: miriam.id, position: pos}
  |> Language.changeset(%{language_code: code, proficiency: level})
  |> Repo.insert!()
end

upload = fn src, name, type ->
  tmp = Path.join(System.tmp_dir!(), name)
  File.cp!(src, tmp)
  %Plug.Upload{content_type: type, filename: name, path: tmp}
end

{:ok, _} =
  Accounts.update_user(user.("miriam_kessler"), %{
    avatar: upload.(Path.join(assets, "miriam_avatar.jpg"), "miriam_kessler.jpg", "image/jpeg")
  })

{:ok, _} =
  Accounts.update_user(user.("miriam_kessler"), %{
    cover_photo:
      upload.(Path.join(assets, "miriam_cover.jpg"), "miriam_kessler_cover.jpg", "image/jpeg")
  })

Repo.query!(
  ~s|update users set avatar_moderation = 'approved', cover_moderation = 'approved', "show_mastodon_feed?" = true, "show_code_stats?" = true, "fediverse_followers?" = true where id = $1|,
  [dump.(miriam.id)]
)

# links with the rendered screenshots of the fictional sites
Repo.delete_all(from(u in Url, where: u.user_id == ^miriam.id))

for {link, pos} <- Enum.with_index(m["links"]) do
  url =
    %Url{user_id: miriam.id, position: pos}
    |> Url.changeset(%{value: link["url"], description: link["desc"]})
    |> Repo.insert!()

  shot = Path.join([assets, "sites-#{lang}", "#{link["site"]}.png"])

  {:ok, file} =
    Vutuv.Screenshot.store({upload.(shot, "#{link["site"]}.png", "image/png"), url},
      trusted: true
    )

  Repo.query!(
    "update urls set screenshot = $1, screenshot_moderation = 'approved', screenshot_attempted_at = $2 where id = $3",
    [file, now, dump.(url.id)]
  )
end

# social accounts; the GitHub card is a stored snapshot (fresh for 7 days, so never fetched)
Repo.delete_all(from(s in SocialMediaAccount, where: s.user_id == ^miriam.id))

repos =
  Enum.zip([["live_planner", 612], ["otp_patterns", 401], ["stammtisch", 88]], m["github_repos"])
  |> Enum.map(fn {[name, stars], desc} ->
    %{
      "name" => name,
      "language" => "Elixir",
      "stars" => stars,
      "url" => "https://github.com/miriam-kessler/#{name}",
      "description" => desc
    }
  end)

github = %{
  "followers" => 214,
  "languages" => ["Elixir", "TypeScript", "Shell"],
  "member_since" => "2014-10-06",
  "public_repos" => 42,
  "recent_repos" => 9,
  "total_stars" => 1287,
  "last_active_at" => DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.to_iso8601(),
  "top_repos" => repos
}

for {{provider, value, stats}, pos} <-
      Enum.with_index([
        {"Mastodon", "miriam@elixir-koblenz.social", nil},
        {"Bluesky", "miriamkessler.dev", nil},
        {"GitHub", "miriam-kessler", github},
        {"LinkedIn", "miriam-kessler-koblenz", nil}
      ]) do
  acc =
    %SocialMediaAccount{user_id: miriam.id, position: pos}
    |> SocialMediaAccount.changeset(%{provider: provider, value: value})
    |> Repo.insert!()

  if stats,
    do:
      Repo.query!(
        "update social_media_accounts set code_stats = $1, code_stats_fetched_at = now() where id = $2",
        [stats, dump.(acc.id)]
      )
end

log.("profile ready")

# ---------- who Miriam follows ----------
for u <- ["anna_berger", "jonas_keller", "lena_hoffmann"], do: Social.follow(miriam, user.(u).id)

for name <- ["Elixir", "Koblenz", "Phoenix Framework", "Community"] do
  case Repo.one(from(t in Vutuv.Tags.Tag, where: t.name == ^name, limit: 1)) do
    nil -> :ok
    tag -> Tags.follow_tag(miriam, tag)
  end
end

# the news accounts of this language, and none of the other language's
all_news = for {_f, cf} <- contents, acct <- cf["news"]["follow"], do: acct

account_id = fn [host, handle] ->
  case Repo.query!("select id from fediverse_remote_accounts where host = $1 and handle = $2", [
         host,
         handle
       ]) do
    %{rows: [[id]]} ->
      id

    _ ->
      raise "remote account @#{handle}@#{host} is not in this database copy; pick another in content.#{lang}.json"
  end
end

for acct <- all_news, acct not in c["news"]["follow"] do
  Repo.query!("delete from fediverse_follows where user_id = $1 and remote_account_id = $2", [
    dump.(miriam.id),
    account_id.(acct)
  ])
end

for acct <- c["news"]["follow"] do
  aid = account_id.(acct)

  if Repo.query!(
       "select 1 from fediverse_follows where user_id = $1 and remote_account_id = $2",
       [dump.(miriam.id), aid]
     ).num_rows == 0 do
    id = UUIDv7.generate()

    Repo.query!(
      "insert into fediverse_follows (id, user_id, remote_account_id, state, follow_activity_id, muted, inserted_at, updated_at) values ($1, $2, $3, 'accepted', $4, false, now(), now())",
      [dump.(id), dump.(miriam.id), aid, "https://vutuv.invalid/teaser/follows/#{id}"]
    )
  end
end

news_post = fn needle ->
  case Repo.query!(
         "select id from fediverse_posts where content_text like $1 and in_reply_to_uri is null order by published_at desc limit 1",
         ["%" <> needle <> "%"]
       ) do
    %{rows: [[id]]} -> id
    _ -> raise "no news post containing #{inspect(needle)}; pick another in content.#{lang}.json"
  end
end

# the other language's headline news go back out of the top of the feed
for {f, cf} <- contents,
    f != lang,
    needle <- [cf["news"]["top_contains"], cf["news"]["second_contains"]] do
  Repo.query!(
    "update fediverse_posts set published_at = now() - interval '3 days', received_at = now() - interval '3 days' where content_text like $1 and published_at > now() - interval '1 day'",
    ["%" <> needle <> "%"]
  )
end

# news picked by an earlier run (maybe with other content) go back out of the feed's top too
picked_file = Path.expand("../../_build/teaser/news-picked.json", here)
previous = if File.exists?(picked_file), do: Jason.decode!(File.read!(picked_file)), else: []

for id <- previous do
  Repo.query!(
    "update fediverse_posts set published_at = now() - interval '3 days', received_at = now() - interval '3 days' where id = $1",
    [dump.(id)]
  )
end

top = news_post.(c["news"]["top_contains"])
second = news_post.(c["news"]["second_contains"])

Repo.query!("update fediverse_posts set published_at = $1, received_at = $1 where id = $2", [
  ago.(20),
  top
])

Repo.query!("update fediverse_posts set published_at = $1, received_at = $1 where id = $2", [
  ago.(21),
  second
])

File.write!(
  picked_file,
  Jason.encode!(Enum.uniq(previous ++ [Ecto.UUID.cast!(top), Ecto.UUID.cast!(second)]))
)

# Miriam has not liked or reposted anything yet, and has no draft lying around
Repo.query!("delete from fediverse_post_likes where user_id = $1", [dump.(miriam.id)])
Repo.query!("delete from fediverse_post_reposts where user_id = $1", [dump.(miriam.id)])
Repo.query!("delete from post_drafts where user_id = $1", [dump.(miriam.id)])
log.("feed ready")

# ---------- Miriam's post, three likes, Anna's reply ----------
replies = for {_f, cf} <- contents, do: cf["reply"]
Repo.delete_all(from(p in Post, where: p.user_id == ^anna.id and p.body in ^replies))
Repo.delete_all(from(p in Post, where: p.user_id == ^miriam.id))

post_body = c["post"]["line1"] <> "\n\n**" <> c["post"]["line2"] <> "**"

{:ok, post} =
  Posts.create_post(miriam, %{
    "body" => post_body,
    "tags" => Enum.join(c["post"]["tags"], ", "),
    "language" => lang
  })

for u <- ["lena_hoffmann", "jonas_keller", "anna_berger"],
    do: :ok = Posts.like_post(user.(u), post)

{:ok, reply} = Posts.create_reply(anna, post, %{"body" => c["reply"], "language" => lang})

Repo.query!("update posts set inserted_at = $1, updated_at = $1 where id = $2", [
  ago.(6),
  dump.(post.id)
])

Repo.query!("update posts set inserted_at = $1, updated_at = $1 where id = $2", [
  ago.(2),
  dump.(reply.id)
])

log.("post ready")

# ---------- the chat: accepted, with only the two opening messages ----------
{:ok, conv} = Chat.find_or_create_conversation(anna, miriam)
Repo.query!("update conversations set status = 'accepted' where id = $1", [dump.(conv.id)])
Repo.query!("delete from messages where conversation_id = $1", [dump.(conv.id)])
{:ok, _} = Chat.send_message(anna, conv.id, c["chat"]["opening_anna"])
Process.sleep(1100)
{:ok, _} = Chat.send_message(miriam, conv.id, c["chat"]["opening_miriam"])
log.("chat ready")

# ---------- job postings ----------
demo_ids = Enum.map(["anna_berger", "jonas_keller", "lena_hoffmann"], &user.(&1).id)
Repo.delete_all(from(j in JobPosting, where: j.user_id in ^demo_ids))
today = Date.utc_today()

main =
  c["jobs"]
  |> Enum.with_index()
  |> Enum.map(fn {j, i} ->
    attrs =
      %{
        "title" => j["title"],
        "hiring_org_name" => j["org"],
        "employment_type" => j["employment"] || "full_time",
        "workplace_type" => j["workplace"],
        "apply_kind" => "message",
        "required_tags" => j["required"] || "Elixir, Phoenix Framework",
        "nice_to_have_tags" => j["nice"] || "",
        "description" =>
          j["desc"] || String.replace(c["job_default_desc"], "{city}", j["city"] || "")
      }
      |> Map.merge(
        if j["zip"],
          do: %{"zip_code" => j["zip"], "city" => j["city"], "country" => j["country"]},
          else: %{}
      )
      |> Map.merge(if j["remote"], do: %{"remote_countries" => j["remote"]}, else: %{})
      |> Map.merge(
        if j["salary"],
          do: %{"salary_min" => Enum.at(j["salary"], 0), "salary_max" => Enum.at(j["salary"], 1)},
          else: %{}
      )

    {:ok, p} = Jobs.create_draft(user.(j["poster"]), attrs)
    published = if j["main"], do: now, else: NaiveDateTime.add(now, -600 - i * 300)

    p
    |> Ecto.Changeset.change(
      status: :published,
      first_published_at: published,
      expires_on: Date.add(today, 60)
    )
    |> Repo.update!()

    {j, p}
  end)
  |> Enum.find_value(fn {j, p} -> if j["main"], do: p end)

log.("#{length(c["jobs"])} jobs ready")

ids = %{
  lang: lang,
  miriam_id: miriam.id,
  post_id: post.id,
  reply_id: reply.id,
  conversation_id: conv.id,
  news_top_id: Ecto.UUID.cast!(top),
  news_second_id: Ecto.UUID.cast!(second),
  main_job_slug: main.slug,
  main_job_title: main.title
}

File.write!(Path.join(out_dir, "ids.json"), Jason.encode!(ids, pretty: true))
log.("done -> #{Path.join(out_dir, "ids.json")}")
