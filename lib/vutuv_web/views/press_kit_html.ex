defmodule VutuvWeb.PressKitHTML do
  @moduledoc """
  The public press page (`/:slug/press`, issue #2086). Everything it draws is
  `VutuvWeb.PressKitComponents`, shared with the profile card and with #2087's
  page twin; this module is the template's home and nothing else.
  """
  use VutuvWeb, :html

  import VutuvWeb.PressKitComponents
  import VutuvWeb.UserHelpers, only: [full_name: 1, same_user?: 2]

  embed_templates("../templates/press_kit/*")
end
