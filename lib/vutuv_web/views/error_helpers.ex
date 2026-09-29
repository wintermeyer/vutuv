defmodule VutuvWeb.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """

  use PhoenixHTMLHelpers
  use Gettext, backend: VutuvWeb.Gettext

  alias Phoenix.HTML.Form

  @doc """
  Every message a rejected changeset carries, oldest first, translated.

  For the two report forms, which have no per-field error slots and show
  everything as one banner: `Vutuv.Moderation.Report`'s messages are whole
  sentences addressed to the reporter, so nothing here has to guess one from a
  field name. `errors` is newest-first, hence the reverse.
  """
  def changeset_messages(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.reverse()
    |> Enum.map(fn {_field, error} -> translate_error(error) end)
  end

  @doc """
  Generates tag for inlined form input errors.

  The span carries a stable `id` derived from the input's own id
  (`url_value_error`), which is what `err_attrs/2` points `aria-describedby`
  at, so a screen reader reads the reason together with the field instead of
  leaving the message orphaned two nodes away.
  """
  def error_tag(form, field) do
    if error = form.errors[field] do
      content_tag(:span, translate_error(error),
        class: "editform__error",
        id: error_id(form, field)
      )
    end
  end

  @doc """
  The accessible state a failed field owes its user, as input options.

  Returns `[]` for a clean field, and for a failed one the pair that makes the
  red border mean something to a person who cannot see it: `aria-invalid`
  (this control is wrong) and `aria-describedby` pointing at the `error_tag/2`
  span right below it (this is why). Colour alone would leave the error
  invisible to a screen-reader or colour-blind user — WCAG 1.4.1 / 3.3.1.

  Pass it as the input's options, appending to any the field already has:

      <%= text_input f, :value, err_attrs(f, :value) %>
      <%= text_input f, :value, [placeholder: "…"] ++ err_attrs(f, :value) %>
  """
  def err_attrs(form, field) do
    if form.errors[field] do
      ["aria-invalid": "true"] ++
        case error_id(form, field) do
          nil -> []
          id -> ["aria-describedby": id]
        end
    else
      []
    end
  end

  # `error_tag/2` is called with a `%Phoenix.HTML.Form{}` on the classic form
  # pages and with a bare `%Ecto.Changeset{}` in a few LiveViews (TagNewLive),
  # which has `.errors` but no input ids to derive one from. Only the form case
  # can name an id, so the changeset case renders the message without one — it
  # still reads, it just cannot be pointed at by `aria-describedby`.
  defp error_id(%Form{} = form, field), do: "#{Form.input_id(form, field)}_error"
  defp error_id(_other, _field), do: nil

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # Because error messages were defined within Ecto, we must
    # call the Gettext module passing our Gettext backend. We
    # also use the "errors" domain as translations are placed
    # in the errors.po file. On your own code and templates,
    # this could be written simply as:
    #
    #     dngettext "errors", "1 file", "%{count} files", count
    #
    if count = opts[:count] do
      Gettext.dngettext(VutuvWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(VutuvWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_error(msg) do
    Gettext.dgettext(VutuvWeb.Gettext, "errors", msg)
  end

  # Extraction anchors: custom `add_error/3` messages live as literal strings
  # inside schema modules, where `mix gettext.extract` cannot see them.
  # Declaring them here with `dgettext_noop` puts the msgids into errors.pot,
  # so `translate_error/1` finds a German msgstr at render time. Keep each
  # string byte-identical to its `add_error` twin.
  @doc false
  def __error_message_extraction_anchors__ do
    [
      # Vutuv.Profiles.Qualification, the proof-document upload (consent gate).
      dgettext_noop(
        "errors",
        "Please confirm that the file may be shown publicly. Without your consent nothing is uploaded."
      ),
      dgettext_noop("errors", "is larger than 10 MB. Please upload a smaller file."),
      dgettext_noop(
        "errors",
        "PDF uploads are not available on this installation. Please upload an image instead."
      ),
      dgettext_noop("errors", "could not be read. Please upload a PDF, JPG, PNG or WebP file."),
      # Vutuv.Accounts.User, the avatar and cover uploads on /settings/profile.
      # The first is `VutuvWeb.UI.upload_problem_message/2`'s sentence for the
      # same refusal, repeated here only because a changeset error reads the
      # "errors" domain rather than the default one.
      dgettext_noop("errors", "That file is larger than %{limit}. Please upload a smaller one."),
      dgettext_noop(
        "errors",
        "We cannot read this file. Please upload one of these formats: %{formats}."
      ),
      # Vutuv.Accounts.User, sign-up: only the address the PIN goes to.
      dgettext_noop("errors", "Only one email address can be given at sign-up."),
      # Vutuv.Tags.Tag / Vutuv.Accounts.User, the "this field is not a
      # billboard" rule (Vutuv.WebAddress).
      dgettext_noop("errors", "must not be a web or email address"),
      dgettext_noop(
        "errors",
        "can't be only a link. Please describe yourself in a few words."
      ),
      dgettext_noop(
        "errors",
        "\"%{tag}\" is a web address, not a tag. Please describe yourself with words."
      ),
      # Vutuv.Accounts.User, the "give us a name" rule. It rode on unnoticed in
      # English for as long as it only ever showed as a small line under a
      # field; the three-step sign-up puts it in a banner, where a German page
      # saying it in English is impossible to miss.
      dgettext_noop("errors", "First name or last name or nickname must be present"),
      # Vutuv.Accounts.User, the spoken-name hint (issue #1112).
      dgettext_noop("errors", "must spell out how the name sounds"),
      # Vutuv.Tags.Tag, a name of punctuation only.
      dgettext_noop("errors", "must not be only punctuation"),
      dgettext_noop("errors", "\"%{tag}\" is only punctuation, not a tag."),
      # Vutuv.Moderation.Report, the report form's one error banner (issue #2008).
      dgettext_noop("errors", "Please pick a category."),
      dgettext_noop("errors", "Your note is too long."),
      dgettext_noop(
        "errors",
        "Please tell us which work it is and where the original can be seen."
      ),
      dgettext_noop("errors", "Please confirm that you are making this claim in good faith."),
      # Vutuv.Moderation.Report, the public notice form (issue #2009).
      dgettext_noop("errors", "Please tell us your name."),
      dgettext_noop("errors", "Please give us an email address."),
      dgettext_noop("errors", "That does not look like an email address."),
      dgettext_noop("errors", "That address is too long."),
      dgettext_noop("errors", "Your name is too long."),
      dgettext_noop(
        "errors",
        "Please tell us what is wrong with this content, in your own words."
      ),
      dgettext_noop("errors", "You already reported this."),
      # Vutuv.Posts, the post tag cap (issue #1237).
      dgettext_noop("errors", "Please use at most %{max} tags."),
      # Vutuv.Mentions, the per-post mention cap (anti-spam).
      dgettext_noop(
        "errors",
        "We allow at most %{max} accounts per post. Please remove some mentions."
      ),
      # Vutuv.Accounts.User, the Fediverse aliases (issue #986, alsoKnownAs).
      dgettext_noop("errors", "Please list at most %{max} accounts."),
      dgettext_noop("errors", "\"%{uri}\" is not a valid https account address."),
      # Vutuv.Profiles.Messenger, the Signal contact link (issue #1442).
      dgettext_noop("errors", "Enter your Signal link, it starts with https://signal.me/#"),
      # Vutuv.Profiles.SocialMediaAccount, the per-provider address shapes.
      dgettext_noop("errors", "Enter your full Mastodon handle, e.g. @user@instance.social"),
      dgettext_noop("errors", "Enter your full Friendica handle, e.g. @user@friendica.example"),
      dgettext_noop("errors", "Enter your full Pixelfed handle, e.g. @user@pixelfed.social"),
      dgettext_noop("errors", "Enter your full BookWyrm handle, e.g. @user@bookwyrm.social"),
      dgettext_noop("errors", "Enter your Bluesky handle, e.g. name.bsky.social"),
      dgettext_noop(
        "errors",
        "Enter your username and your instance, e.g. name@git.example.com"
      ),
      dgettext_noop(
        "errors",
        "Enter your GitLab username, e.g. gitlab.com/username (not a /-/u/ ID link)"
      ),
      dgettext_noop(
        "errors",
        "Enter your GitHub username, not a full URL with extra path segments"
      ),
      dgettext_noop(
        "errors",
        "Enter your Codeberg username, not a full URL with extra path segments"
      ),
      dgettext_noop("errors", "Invalid account name"),
      dgettext_noop("errors", "Someone has already claimed this account"),
      # Vutuv.CodeStats, the self-hosted forge admission check (issue #1504) and
      # its rate limit in VutuvWeb.SocialMediaAccountController.
      dgettext_noop(
        "errors",
        "We could not find this account on that instance. Please check the address."
      ),
      dgettext_noop("errors", "That instance did not answer. Please try again in a moment."),
      dgettext_noop("errors", "Too many checks for now. Please try again later."),
      # Vutuv.ScreenshotTrust.Host, the admin's trusted-sites form.
      dgettext_noop("errors", "must be a site without a path, e.g. tagesschau.de"),
      # Ecto's `validate_number/3` interpolates %{number}, not %{count}, so the
      # plural entries above never match it (feed page size, post lines).
      dgettext_noop("errors", "must be less than %{number}"),
      dgettext_noop("errors", "must be greater than %{number}"),
      dgettext_noop("errors", "must be less than or equal to %{number}"),
      dgettext_noop("errors", "must be greater than or equal to %{number}"),
      dgettext_noop("errors", "must be equal to %{number}"),
      # Vutuv.Accounts.Email / Vutuv.Accounts.User.
      dgettext_noop("errors", "must be a valid email address"),
      dgettext_noop("errors", "is not a known time zone"),
      dgettext_noop("errors", "can't be in the future"),
      dgettext_noop("errors", "is not a valid birthdate"),
      # Vutuv.ChangesetHelpers / Vutuv.Profiles.Qualification, CV date ranges.
      dgettext_noop("errors", "If month is present, year must be present."),
      dgettext_noop("errors", "End date must be later than start date"),
      dgettext_noop("errors", "Expiry must not precede the award date."),
      # Vutuv.ContentFilters.ContentFilter and Vutuv.Mutes.AccountMute.
      dgettext_noop("errors", "may use at most %{max} wildcards (*)."),
      dgettext_noop("errors", "must contain something to match, not only wildcards"),
      dgettext_noop("errors", "you already mute this"),
      dgettext_noop("errors", "You cannot mute yourself."),
      # Vutuv.Profiles.PhoneNumber / Messenger / Url.
      dgettext_noop("errors", "Please enter a valid phone number"),
      dgettext_noop("errors", "This field is required"),
      dgettext_noop("errors", "You have already added this messenger"),
      dgettext_noop("errors", "Enter a phone number or a username"),
      dgettext_noop("errors", "is not a valid image"),
      # Vutuv.References.JobReference.
      dgettext_noop(
        "errors",
        "Please confirm that this reference is yours to upload. Somebody else's reference needs their explicit agreement first."
      ),
      dgettext_noop(
        "errors",
        "is missing. Upload the document, or paste the text of the reference."
      ),
      dgettext_noop(
        "errors",
        "Please confirm that this reference may be shown publicly. Without your consent it stays private."
      ),
      # Vutuv.Organizations and its domain and name schemas.
      dgettext_noop("errors", "is not a valid country"),
      dgettext_noop("errors", "must start with http:// or https://"),
      dgettext_noop("errors", "is not a valid URL"),
      dgettext_noop("errors", "is not an allowed address"),
      dgettext_noop("errors", "is not a valid domain"),
      dgettext_noop("errors", "is not an allowed domain"),
      dgettext_noop("errors", "is required to verify the domain"),
      dgettext_noop("errors", "is already listed for this organization"),
      # Vutuv.Tags.Tag.
      dgettext_noop("errors", "must be a single line"),
      # Vutuv.ApiAuth.App / Token and Vutuv.Webhooks.Subscription, /settings/apps.
      dgettext_noop("errors", "must each be at most 255 characters"),
      dgettext_noop(
        "errors",
        "must be exact https:// URLs (http://localhost is allowed for development)"
      ),
      dgettext_noop("errors", "needs at least one redirect URL"),
      dgettext_noop("errors", "select at least one permission"),
      dgettext_noop(
        "errors",
        "must be an https:// URL (http://localhost is allowed for development)"
      ),
      dgettext_noop("errors", "must not point at a private, loopback or link-local address"),
      dgettext_noop("errors", "select at least one event"),
      # Ecto's own `unique_constraint/3` default, missing from the stock list.
      dgettext_noop("errors", "has already been taken"),
      # Vutuv.Social.Follow, Vutuv.Tags.TagFollow and TagFollowSource.
      dgettext_noop("errors", "You're already following this person."),
      dgettext_noop("errors", "You're already following this organization."),
      dgettext_noop("errors", "Cannot follow yourself"),
      dgettext_noop("errors", "You're already following this tag."),
      dgettext_noop("errors", "This page already follows this tag."),
      dgettext_noop("errors", "This follow already reads that source."),
      dgettext_noop("errors", "is not an allowed server"),
      # Vutuv.Ads, booking a day and redeeming a code.
      dgettext_noop("errors", "is outside the booking window"),
      dgettext_noop("errors", "has already been used"),
      dgettext_noop("errors", "is already over")
    ]
  end
end
