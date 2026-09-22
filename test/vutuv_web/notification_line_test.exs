defmodule VutuvWeb.NotificationLineTest do
  use ExUnit.Case, async: true

  alias VutuvWeb.NotificationLine

  describe "quote_source/1" do
    test "a reaction quotes the post it reacted to" do
      assert NotificationLine.quote_source(%{kind: "like", post_id: "own"}) == {:post, "own"}
    end

    test "a reply quotes the words that were written, not the post it answers" do
      item = %{kind: "reply", post_id: "own", reply_post_id: "answer"}
      assert NotificationLine.quote_source(item) == {:post, "answer"}
    end

    test "a remote reply with no text of its own quotes nothing, never the reader's post" do
      item = %{kind: "fediverse_reply", post_id: "own", note_text: nil}
      assert NotificationLine.quote_source(item) == nil

      assert NotificationLine.quote_source(%{item | note_text: "Hallo"}) == {:note, "Hallo"}
    end

    test "a kind with no post quotes nothing" do
      assert NotificationLine.quote_source(%{kind: "follower"}) == nil
    end
  end
end
