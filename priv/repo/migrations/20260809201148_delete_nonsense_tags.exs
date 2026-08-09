defmodule Vutuv.Repo.Migrations.DeleteNonsenseTags do
  use Ecto.Migration

  @moduledoc """
  Removes tags that carry no meaning: machine-generated random strings, spam
  referral URLs, markup fragments, keyboard mash and bare numbers.

  The bulk of the list is one class: 238 names of the shape
  `afGDzlNQdUGHVirajSvNUBjg` — twelve or more letters, six or more case
  changes, and almost no vowels. They were created in bulk, carry no members
  and describe nothing. The remainder is hand-picked: referral links
  (`cocmoney.club`, `paytime.top`), an HTML fragment, `test` / `aaa` / `asd`,
  names consisting only of digits or punctuation, a few personal names and
  some advertising phrases.

  ## Matching

  Names are matched **exactly**, so a deployment that never collected these
  strings simply deletes nothing and the migration is a no-op. That is the
  normal outcome on any installation other than the one this list was read
  from, and it is why nothing here raises when a name is absent.

  Single-letter language names (`c`, `r`, `d`) were deliberately taken out of
  the list even though they look like noise: `c` alone carries three-digit
  member usage. `RedHatLinuxEnterprise` was excluded for the same reason — it
  is Red Hat Enterprise Linux run together, and it tripped the random-string
  detector.

  ## What goes with a tag

  Six of the seven foreign keys into `tags` cascade (`user_tags`,
  `post_tags`, `post_hashtags`, `tag_follows`, `job_posting_tags`,
  `fediverse_post_tags`), so the memberships and post links go with the row.

  The seventh does not: `newsletter_groups.tag_id` is `ON DELETE SET NULL`, so
  deleting a tag an operator built a newsletter group on would silently empty
  that group's target instead of failing. Such tags are therefore **skipped**,
  not deleted — a tag someone deliberately wired a newsletter to is in use,
  whatever its name looks like. The count of skipped tags is logged.

  ## Reversibility and deploy safety

  Irreversible: `down/0` is a no-op, because the memberships that cascade away
  cannot be reconstructed. Restore from a backup if this ever has to be undone.

  N-1 safe on its own. No schema changes, and the previously deployed release
  keeps working: a tag it can no longer find behaves exactly as a tag a member
  never created.
  """

  @nonsense_tags [
    "a producer I Write",
    "A-Z",
    "A_ Sehr netter Recruiter",
    "Abbasi 786",
    "Alibaba.com buyer",
    "Aliexpress enthusiast",
    "AllyxFoe",
    "AnnCruz",
    "anton meyer",
    "Am a good person",
    "alles",
    "Ansatz: Das Wissen liegt im System",
    "Begging",
    "Bdcash",
    "Cardboard Boxes",
    "Custom Boxes",
    "Custom Packaging",
    "City Sunglass",
    "Cash Loans",
    "cash hunting",
    "Cheap Phone Calls South Africa",
    "Make Money On The Internet",
    "Costa Rica's Call Center",
    "Doctor Who and much more.",
    "Dubai Living",
    "Dubai Real Estate Investments",
    "linux ...)",
    "new ways of ...",
    "a",
    "E",
    "5",
    "4000",
    "10008",
    "2026",
    "-",
    "365",
    "389",
    "23",
    "1",
    "2",
    "966935",
    ".",
    "https://www.sbasf.com/",
    "test",
    "aaa",
    "www.HR-Terminal.com",
    "http://cocmoney.club/681146722867",
    "https://paytime.top?mref=%40joena",
    "http://www.cashcrate.com/7636933",
    "http://paidviewpoint.com/?r=n6ngcs",
    "<h1>younglord<h1>",
    "asd",
    ".....mnvvv .mkcc ....",
    "afGDzlNQdUGHVirajSvNUBjg",
    "aGufaVptWujwLAwvX",
    "aIElPrkQDWzWyhxJViIgLVN",
    "AkyiTnnfpFjkKvfbujGxJ",
    "AmlaAoQPiLDpigGwLxA",
    "aqlkEWhjXEjDnwrJTzhQp",
    "aqziUfjpFOVOygDEf",
    "AsXQrDhUHQKtpBotujRiQ",
    "AtjhgueOchORcPjiwdkMPor",
    "AuyauIXGQPGmHOptqrlPZ",
    "AvAiKVZSpaVLrLPkpHOlMc",
    "AVPZxmMiCtbgQNvvD",
    "aWidhhWkhqbjvkVySXuzMF",
    "ayCVmFlWeUutZvuWsTrsIAp",
    "bBFePuXJzZSeSEoRyPHbjUY",
    "BEZBMzmoahjlUrTbVf",
    "bIfHQQFEedicyfURUbHmnHkU",
    "BIFVvwreUvcAUUVCdFNVVHO",
    "boAqqcKTgZkFADmo",
    "BRASvLAdTZYmnwYe",
    "BRBChJWJnaTwZpTu",
    "BSvKrmtbtNEvXULrrO",
    "BvxoNSsIADkOFOnS",
    "bxTFBjmkPBZpTipaCAla",
    "BYLhTKUFHnULtqxXX",
    "CbHyOkHMEGffFqViPI",
    "ceDUaAJoqcJqbVOMinCgN",
    "cHjrIYXWtSXQbqnQkedq",
    "cKywvcaSwIhRlFqHqI",
    "cLBCvarNlKNwRLlyvavSrm",
    "cnGbFtuBUjTduJMNYMZcFOAk",
    "coWsPpAmUSIKfEMiqZTQodIh",
    "CwoxjLQjHRZDXUyVtKTwb",
    "DakaNmSdBYJwzmjY",
    "dCJMmxwTYuEkUCeWNKsmLd",
    "dDGaqMmgXAmdqkVkN",
    "dfIbVEeWstYhqPyJEBMOPw",
    "dgthGrVmKuhJJAfWEfZjM",
    "dkQbnaFqJGJYaheyMxl",
    "DpoAQqBASibzlHlT",
    "dQfSlKzzHbLshNaysIqhYZL",
    "DreFfkaEuTdBpczmLElbxrH",
    "DUMXjqRuvtWTjknanAcSrUZE",
    "dUVPCNdxHWuTngclNFUaZR",
    "ecWtRhqOqzbVIzsSaoLKIf",
    "eFSNzCdgtpzchGpMJMvUlH",
    "EjQYiQpQfQTcxkFf",
    "ElxgcwlUvTDSHxitCjEkIo",
    "eMsjylUwUlSjPzryIuYWjETs",
    "enMEcLpQHFtdApwqDhnUQhoj",
    "ExOCyXFaMHlWJwvdTMIkrte",
    "fcLasYIkqLGnVQrOFWfVphV",
    "fdUTPxyNYPhRrRQlqXTHf",
    "FEtAnUsvZFUcKlCH",
    "FFiXoAsgZkYAUpwKGV",
    "FFQMGvEbUnRdvvbbQVXWou",
    "FFVDqAydknCqwvHZZwG",
    "FjFKaKSBOelpblFJbF",
    "fMQGTReZuOOHlOFSuBuafx",
    "FpmyuMYgBwaRnFDLuiPofgk",
    "fPOjywIuaMTAkXOkdUMdETxN",
    "FRPjngDowNojLmjcpvKvRZ",
    "fsBrUnELXYgQkxmbwE",
    "FtvgPmrkerxxVgdyWDTxw",
    "FTYhAEyAZdQmdpghBlNM",
    "FwpmrgsiJZGhaULtepM",
    "fxVpeRdhQmmfzlBCPhmuUu",
    "GBlIMPjglqOgYiGYWXTuywju",
    "GdUHXvarEklXbEOuwpezQWyw",
    "GfcwXMCnRCLMItFimwYNpV",
    "GMbyBuSjXZBlmqUbepDwBS",
    "GPpVDXXUSaLGDnyuaD",
    "GqbpOsEFNlkvIqpIG",
    "GQZcLMSYNKzqQduQWMkuPb",
    "gRpBLvUcQHYIdKeN",
    "GrXOwlZPbrBbKXjjVgX",
    "gVcEIWyyFuxsEKUDpSyayCJF",
    "GYfXtFQKNkQNzgfZqSIqssWV",
    "hOmVHnAqXthXaksqaLcwHPk",
    "hSKIOfFxeNBHfWnDSUPNt",
    "hTlyMgqlYEMCxcJTtihx",
    "HwTIqMSMjoAqYladqx",
    "HYrGfNawVYOPgeYJaoiofMt",
    "HzbnCgOCmcsnLSrETFE",
    "hzCRcTQLTWHNkstePKkjbgcs",
    "iCslBGbrvwSyCeXtTCco",
    "IFGXQczoqLnEhUnonzAoIWZb",
    "IHPXqSqbzXDrZljAPMKxS",
    "iiFboExyUVyxVDsCuM",
    "iKjpLJeILuDUsQzhz",
    "imEIarTKXfmASTOuOmtvTQ",
    "inQdnDxeflDsJxPlccWncLBL",
    "IOuWSAxXfmlQikhBpro",
    "ipbpnNibtiWBdDZAkNEGke",
    "JBYcxxdzYfcRogtLaTVtMyHb",
    "jDxOvYNszWJvHlhPN",
    "jFDUoKBxriEHtTUDASvk",
    "jfeloYTqGYORfEFdiRR",
    "jgzBuEUxhiXMinHJdu",
    "JJMvttKSPXKIyBDsctGLHnYx",
    "JjUYpqSgpaGdKQcQRbQqn",
    "jLvQcRXYFIdaGZbXwT",
    "jNiQzZHLxkoFeCNbIafNjoJ",
    "JOFfOWXNFnGWJNUzlYippv",
    "JTKTModQeeGSubSThWw",
    "JubATgejwEmeRrWIiJIHy",
    "jvRHSHIZTifVQlKBsKi",
    "KexqpJjgQrgsJylzvSE",
    "KgdHsDQRHqpkQIsBlN",
    "KHoHJMCjnQcHeyui",
    "KjjdTfcnSBQaVYhPD",
    "KKMkLtUxsEymFUvaq",
    "knSmYyrJjMchiRxarAajkF",
    "kSuNsqTIXYWeHQdFlNeYgiVX",
    "lHqPNcvGdOJUWPDLotW",
    "lIReWpcBvveLYlWyhra",
    "lJMysDaLbwVpixexULGgmc",
    "lSTQyMQYmfuVCuSIFzOLT",
    "lTVtscVwdbgsZWiEgW",
    "lyEerqCMgbONTKkU",
    "MBeJAInfmhdBuRiQzxD",
    "mIhlfohISbTxhrPMyxfgkN",
    "mjWiUtPTJrHibquLOZWz",
    "mKtdAFgmaiOACtLqognsp",
    "MqPUyJVhrpuyuEJXm",
    "MWEQHyINfYzaPpIF",
    "MWGZmnwPwvgGgxldeSMpPOXj",
    "NByJgOcJyrRtvoRcsxyTXzJ",
    "nkqonuMyJxLHaHZJMLghfgh",
    "nnyQXYknciVjlvQmBrlwI",
    "OAwObgSJHGAxVuhTU",
    "OghuGSfNrIoDYMDL",
    "OhbEppdsJHFhjFtEE",
    "oInkByYmfUxmkjPv",
    "ONrEqUfMdLBjfEqctsRhiS",
    "OpnjWXvvShvXtRFo",
    "oRvlIJhJxAFAUjFZuiXSQ",
    "ouQrwVVUvgqOVKSjCUvoz",
    "ovmjhHaCPgeRHXDpc",
    "oWMRMmQUmbwfqzvSXCcnC",
    "OXQMwXeSaYrpCISTBuJ",
    "pCzhuidjVbmnxdFcqcWQ",
    "PhVuTcPJnMrFnfcMnvLus",
    "pHzrfJvkuIfXWLEPRFN",
    "PnGbbyVxedvaoXAN",
    "PpIPJKnsRcDAzwPiciKs",
    "puzNOzaYodtXakJPAYYe",
    "qapmmtwRtQExUQxinftiS",
    "QaTKlUtVSMTQwZLXBXDcRwA",
    "qaUxbuRxanTzvpjKudkwI",
    "QflRIdgoMgFQtVeB",
    "qGHhqIQToBGFowsxYE",
    "qhRvRGsKsZVrxbiFSqx",
    "QjbncojcKZjStNKFyraPCN",
    "QNkqQeZTgLPCevKiYh",
    "qOKfVbZBrBvDDwPejm",
    "QPvXYkVnHHCVSpmH",
    "QUkKJwTTYIWcHDaZiTUCEMb",
    "QVpuooGjHYBHTnbcSup",
    "RdCWQFLohQJfFrWNl",
    "rGeESuSvDZptxUfyepDIAuJM",
    "rGOOQgjUsxBRgVJRmA",
    "rIGJLdrxeMlTvlhzgvqVsXHP",
    "riIvzvHQQXgPCPNxcog",
    "RKjRUqufxOGkdigRRcMRFLmQ",
    "RMAwrtHcGcusioyCQ",
    "rQWpTfWoZaXRJzFVcDrj",
    "rTQWvkaYYPJHtlJom",
    "rUyraeTUZvLSXtSPMFDWsI",
    "sDScAnQXmoClgfcDy",
    "sHTsWdGpkpNZxtQLXxChRN",
    "smoOYnDaKKFrtfJwkTpTwbP",
    "SnRoBOatxQujmNhWxBFdQqY",
    "SNyyNUGyoPElTxfLDniUUYM",
    "SqoQKXJjeQyTiOmWF",
    "SuWwZDBJYwUPKZRlnq",
    "svjHDQKSVwgdMxJgKN",
    "SxPCUlJIWqykQNbe",
    "szDYgoAREPaCRPdmvfyE",
    "ToddrJHHXvAqPhxASVO",
    "ToimKlXMhpUZDvnKNnpFvDCs",
    "TPeZVSYCHreUBTJOvU",
    "tpjvDnBYMPDMJeZx",
    "trwJGBoLQNhuCutFa",
    "tyxKJMbSxHGDbejoEAq",
    "UBPEAkPXSzsPpUvVqS",
    "uMKudxNJgwHIoqgRBvV",
    "UXVQaanQfZtbRmxwpCHof",
    "vJlpawnUvYEcUuHrtsTvBM",
    "VkEpmoOdTbYmABWprjJdf",
    "vkNlizEaCQgrGZqKQ",
    "vKyhfJocZMEckeJFTejFbOU",
    "VtWbgSLTsIHJVytiIlLjtIte",
    "VYzeWsjDVLgiqtlAESP",
    "wbJvrTftNUbpHbpWpLF",
    "wEZuXmTeAqvoroWDCQ",
    "wGbylxnUrhYbjFEvOzConTnm",
    "wiwGeUQgZOOqSJmqzy",
    "wkMzAdgCuqxPcwGnpwQ",
    "wMkpeTGfbEGkrDpO",
    "wrVsjDTrQnLCodfaIFrFFjtg",
    "WtpaYyIwrthWFbGwahU",
    "WUWHYKVPZnnMpOEAeGX",
    "WzKkLtbJlkQpKjxLkSh",
    "XBJHnDPKIRYhVBtGRNlxp",
    "XCMNCUxRaWgHoSVkL",
    "xEokGSgSlnDkQDoxcsesT",
    "XIckdiRzSkOqIzHeKITfPZY",
    "xigMelqTCPHnmYhQXt",
    "XjMfYfDNIQjAwDinpSSI",
    "xPgSPDqGJfubcBRqZxKm",
    "XrqlxVqJzMQxaLpjS",
    "XsWOZVSzVGpDLdukGOTsId",
    "XUXKhuXrSWMFQDiXDXkIxH",
    "XvIsEPHGClFezlNm",
    "xvlcxVkQvyHushfMGCJaTv",
    "XzazjQgJGntqXtdAIQniUu",
    "XzhsqlINmvMlknDGdmHs",
    "ycwAcRRYiCQfQZvqknO",
    "YePJBgtTCHueZFnMJItVPlSX",
    "YHfDcBzysypupAWzuJKjp",
    "yjjrPumbiYqwBoHuDn",
    "yNnUAhZMBpXHuGWPNfgZdTSP",
    "YNuTBDbeenDTVOCTvxlPwfvz",
    "YTnvYTCJnWjABzqpdP",
    "yVfBHMXbyQHYOeXVGv",
    "yvvUDrTFknXEVmAq",
    "ZdBoUBZeNxvTlQGL",
    "ZdDCniQRYmvyuuXegqVRjmG",
    "zDvvEZtcndVsCRraYcjlI",
    "ZfTincjIkaFRbFIR",
    "zJJYlpDTLygDHSNkjkagltW",
    "znEMlNktVHLzOLJq",
    "ZrlWmJmWOwHknjHtC",
    "zRTHLrJMopipgRRIwjZPL",
    "ZtHhlqFPaswoRcJYrWGNw",
    "zWNCqivhhUWmlfolIBzw",
    "zwWXAzaUDfwfnFmD"
  ]

  @doc """
  The exact tag names this migration removes. Public so the accompanying test
  can seed and assert against the same list instead of a copy that can drift.
  """
  def nonsense_tags, do: @nonsense_tags

  @protected """
  SELECT count(DISTINCT t.id)
  FROM tags t
  JOIN newsletter_groups g ON g.tag_id = t.id
  WHERE t.name = ANY($1::text[])
  """

  @delete """
  DELETE FROM tags t
  WHERE t.name = ANY($1::text[])
    AND NOT EXISTS (SELECT 1 FROM newsletter_groups g WHERE g.tag_id = t.id)
  """

  @doc "The statement `up/0` runs. Public so the test exercises this SQL, not a copy of it."
  def delete_sql, do: @delete

  @doc "The skip-count statement `up/0` runs, exposed for the same reason as `delete_sql/0`."
  def protected_count_sql, do: @protected

  def up do
    %{rows: [[protected]]} = repo().query!(@protected, [@nonsense_tags])
    %{num_rows: deleted} = repo().query!(@delete, [@nonsense_tags])

    IO.puts(
      "delete_nonsense_tags: #{deleted} of #{length(@nonsense_tags)} listed tags deleted" <>
        ", #{protected} skipped (referenced by a newsletter group)"
    )
  end

  def down do
    IO.puts("delete_nonsense_tags: irreversible, nothing to undo")
    :ok
  end
end
