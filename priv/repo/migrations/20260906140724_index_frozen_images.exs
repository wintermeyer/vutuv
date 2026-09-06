defmodule Vutuv.Repo.Migrations.IndexFrozenImages do
  use Ecto.Migration

  # The copyright freeze's due list (issue #2012): `Vutuv.Images.reconcile_holds/0`
  # asks for every held picture every 15 minutes, and without this that is a
  # sequential scan of a table holding every picture on the installation —
  # 1,747 rows on vutuv.de today, all of them once #2015 has moved the rest in.
  #
  # Partial, because the answer is almost always none: the index holds a row
  # only while a case is open, so on a healthy installation it is empty and the
  # sweep is one probe. A plain addition, so it is N-1 safe on its own.
  def change do
    create(index(:images, [:frozen_at], where: "frozen_at IS NOT NULL"))
  end
end
