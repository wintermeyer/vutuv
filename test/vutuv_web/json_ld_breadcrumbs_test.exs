defmodule VutuvWeb.JsonLdBreadcrumbsTest do
  @moduledoc """
  The profile's `breadcrumbs/1` against the general `breadcrumb_trail/1` it now
  delegates to. The expected map here is the one the hand-written second copy
  built, spelled out literally rather than derived, so this fails if the
  delegation ever renders the profile trail differently — which is the whole
  risk of collapsing two builders into one.
  """
  use VutuvWeb.ConnCase, async: true

  alias VutuvWeb.JsonLd
  alias VutuvWeb.UserHelpers

  test "the profile trail is the site root then the member" do
    user = insert(:activated_user)
    profile_url = VutuvWeb.Endpoint.url() <> "/" <> user.username

    assert JsonLd.breadcrumbs(user) == %{
             "@context" => "https://schema.org",
             "@type" => "BreadcrumbList",
             "itemListElement" => [
               %{
                 "@type" => "ListItem",
                 "position" => 1,
                 "item" => %{
                   "@id" => VutuvWeb.Endpoint.url(),
                   "name" => Vutuv.SiteName.get()
                 }
               },
               %{
                 "@type" => "ListItem",
                 "position" => 2,
                 "item" => %{
                   "@id" => profile_url,
                   "name" => UserHelpers.full_name(user)
                 }
               }
             ]
           }
  end

  test "it is exactly the general trail with one linked crumb" do
    user = insert(:activated_user)

    assert JsonLd.breadcrumbs(user) ==
             JsonLd.breadcrumb_trail([{UserHelpers.full_name(user), "/" <> user.username}])
  end
end
