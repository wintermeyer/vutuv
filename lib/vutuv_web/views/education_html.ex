defmodule VutuvWeb.EducationHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers
  # The month select options and the date-range formatter are identical to a
  # work experience's; reuse them rather than duplicate the logic.
  import VutuvWeb.WorkExperienceHTML,
    only: [month_options: 0, format_duration: 4, format_duration: 5]

  embed_templates("../templates/education/*")
end
