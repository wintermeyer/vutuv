defmodule Vutuv.Jobs.SweeperTest do
  use Vutuv.DataCase, async: true

  import Swoosh.TestAssertions
  import Vutuv.JobsHelpers

  alias Vutuv.BerlinTime
  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Jobs.Sweeper
  alias Vutuv.Repo

  test "flips an overdue posting to expired" do
    posting = publish_job!()
    yesterday = Date.add(BerlinTime.today(), -1)

    Repo.update_all(from(p in JobPosting, where: p.id == ^posting.id),
      set: [expires_on: yesterday]
    )

    assert Sweeper.sweep(BerlinTime.today()) == 1
    assert Repo.get(JobPosting, posting.id).status == :expired
  end

  test "e-mails the poster when a posting expires in 7 days" do
    poster = poster_fixture()
    _email = insert(:email, user: poster)
    posting = publish_job!(poster)

    in_seven = Date.add(BerlinTime.today(), 7)

    Repo.update_all(from(p in JobPosting, where: p.id == ^posting.id),
      set: [expires_on: in_seven]
    )

    Sweeper.sweep(BerlinTime.today())

    assert_email_sent(fn email ->
      assert email.subject =~ "expires soon" or email.subject =~ "läuft"
      assert email.text_body =~ posting.title
    end)
  end

  test "leaves a posting that is not yet due" do
    posting = publish_job!()
    # expires_on is 90 days out by default.
    assert Sweeper.sweep(BerlinTime.today()) == 0
    assert Repo.get(JobPosting, posting.id).status == :published
    assert Jobs.effective_status(Repo.get(JobPosting, posting.id)) == :published
  end
end
