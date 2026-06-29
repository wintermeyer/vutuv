defmodule VutuvWeb.NewsletterTokenTest do
  @moduledoc """
  The signed click-tracking token: it must round-trip a (newsletter, recipient)
  pair and reject anything tampered with or signed for a different purpose.
  """
  use Vutuv.DataCase

  alias VutuvWeb.NewsletterToken

  test "signs and verifies a newsletter + recipient pair" do
    newsletter_id = Vutuv.UUIDv7.generate()
    user_id = Vutuv.UUIDv7.generate()

    token = NewsletterToken.sign(newsletter_id, user_id)
    assert {:ok, ^newsletter_id, ^user_id} = NewsletterToken.verify(token)
  end

  test "rejects garbage and non-tokens" do
    assert :error = NewsletterToken.verify("not-a-token")
    assert :error = NewsletterToken.verify(nil)
    assert :error = NewsletterToken.verify(123)
  end

  test "rejects a token signed with the wrong salt (e.g. an unsubscribe token)" do
    user = insert(:user)
    assert :error = NewsletterToken.verify(VutuvWeb.UnsubscribeToken.sign(user))
  end
end
