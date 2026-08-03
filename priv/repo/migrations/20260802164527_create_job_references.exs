defmodule Vutuv.Repo.Migrations.CreateJobReferences do
  use Ecto.Migration

  @moduledoc """
  A member's Arbeitszeugnis (German employment reference): the document plus
  the plain text an AI check reads. Modelled on `qualifications` — same
  consent-gated document columns, same moderation column — because it is the
  same shape of thing: a credential a member may or may not want shown.

  Two differences worth naming. The text lives here as a column rather than
  only in the file: a member may paste a Zeugnis without uploading anything,
  and the check reads the text, never the PDF. And `public?` defaults to
  false, unlike a qualification's document, because a Zeugnis carries an
  employer's judgement of a person and the safe default is "nobody sees it".
  """

  def change do
    create table(:job_references) do
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false)

      # The member's own label for the entry ("Zeugnis Muster GmbH 2019-2026").
      add(:title, :string, null: false)
      # The employer who issued it. Free text: an organization page may not
      # exist, and a former employer may be gone entirely.
      add(:employer, :string)
      # qualified | simple | interim | apprenticeship | service — the Zeugnis
      # kinds German law distinguishes (§ 109 GewO, § 630 BGB, § 16 BBiG).
      # Validated in the schema, a plain string here.
      add(:kind, :string, null: false, default: "qualified")
      # The Ausstellungsdatum printed on the document. Optional: a member
      # pasting a text may not have it to hand.
      add(:issued_on, :date)

      # Which country's employment law the document was issued under (ISO
      # 3166-1 alpha-2). Not decoration: the AI check reads German Zeugnisrecht
      # (§ 109 GewO plus BAG case law), and the neighbours differ enough that
      # applying it elsewhere would be wrong rather than merely imprecise —
      # Austria (§ 39 AngG) forbids the coded grading this analysis decodes,
      # Switzerland (Art. 330a OR) has its own practice and case law. So the
      # check is offered per entry by country, and everything else about a
      # reference works the same everywhere. No DB default: the schema fills it
      # from `Vutuv.Geo.default_country/0`, which each installation configures.
      add(:country, :string, null: false)

      # The Zeugnis text itself — what the AI check actually reads. `text`, not
      # varchar: a multi-page Zeugnis runs well past 255 characters, and the
      # schema caps it at 50_000 (~13_500 tokens), which leaves room in the
      # model's 65_536-token window beside the ~35_200-token skill prompt.
      add(:body, :text)
      # How that text was obtained: typed | pdf_text | ocr_tesseract |
      # ocr_vision. Shown to the member, because OCR text needs proofreading —
      # a vision model normalises rather than misreads ("Kundenstammdaten"
      # became "Kundendaten" in testing), so its errors look like correct text.
      add(:body_source, :string)

      # The public-display choice. Default false and deliberately so: this is
      # the one column whose wrong default is a privacy incident, not a bug.
      # `public_consented_at` records when the member ticked the box, the same
      # evidence trail `qualifications.document_consented_at` keeps.
      add(:public?, :boolean, null: false, default: false)
      add(:public_consented_at, :utc_datetime)

      # The uploaded document (PDF or image), all optional — a pasted-text
      # entry has none. Mirrors the qualification document columns so the
      # storage module, the proxy and the moderation hook keep the same shape.
      # `document_moderation` is NULL when there is no file.
      add(:document, :string)
      add(:document_fingerprint, :string)
      add(:document_content_type, :string)
      add(:document_size, :integer)
      add(:document_moderation, :string)
      add(:document_page_count, :integer)

      timestamps()
    end

    create(index(:job_references, [:user_id]))

    # The public profile lists a member's public entries newest first; this
    # covers that read without carrying the private ones in the index. The
    # column name ends in `?`, so the partial-index predicate has to quote it.
    create(
      index(:job_references, [:user_id, :issued_on],
        where: ~s|"public?" = true|,
        name: :job_references_public_by_date_index
      )
    )
  end
end
