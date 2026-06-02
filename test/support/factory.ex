defmodule Vutuv.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: Vutuv.Repo

  def user_factory do
    %Vutuv.Accounts.User{
      first_name: sequence(:first_name, &"User#{&1}"),
      last_name: "Test",
      active_slug: sequence(:active_slug, &"user-#{&1}"),
      locale: "en"
    }
  end

  def email_factory do
    %Vutuv.Accounts.Email{
      value: sequence(:email_value, &"user#{&1}@example.com"),
      public?: true,
      md5sum:
        sequence(
          :md5sum,
          &(:crypto.hash(:md5, "user#{&1}@example.com") |> Base.encode16() |> String.downcase())
        )
    }
  end

  def slug_factory do
    %Vutuv.Accounts.Slug{
      value: sequence(:slug_value, &"user-slug-#{&1}")
    }
  end

  def search_term_factory do
    %Vutuv.Accounts.SearchTerm{
      value: sequence(:search_term_value, &"term-#{&1}"),
      score: 100
    }
  end

  def magic_link_factory do
    %Vutuv.Accounts.MagicLink{
      magic_link: sequence(:magic_link, &"magic-link-hash-#{&1}"),
      magic_link_type: "login",
      magic_link_created_at: NaiveDateTime.utc_now(),
      pin: "123456",
      pin_login_attempts: 0
    }
  end

  def address_factory do
    %Vutuv.Profiles.Address{
      description: "Home",
      country: "Germany",
      city: "Berlin",
      zip_code: "10115"
    }
  end

  def phone_number_factory do
    %Vutuv.Profiles.PhoneNumber{
      value: sequence(:phone_value, &"+49 30 #{&1}00000"),
      number_type: "mobile"
    }
  end

  def social_media_account_factory do
    %Vutuv.Profiles.SocialMediaAccount{
      provider: "GitHub",
      value: sequence(:social_value, &"user#{&1}")
    }
  end

  def url_factory do
    %Vutuv.Profiles.Url{
      value: "http://example.org/",
      description: "Test Url"
    }
  end

  def work_experience_factory do
    %Vutuv.Profiles.WorkExperience{
      title: "Developer",
      organization: "Acme Corp",
      description: "Building things",
      start_month: 1,
      start_year: 2020,
      slug: sequence(:work_slug, &"developer-acme-#{&1}")
    }
  end

  def skill_factory do
    %Vutuv.Profiles.Skill{
      name: sequence(:skill_name, &"Skill #{&1}"),
      downcase_name: sequence(:skill_downcase, &"skill #{&1}"),
      slug: sequence(:skill_slug, &"skill-#{&1}")
    }
  end

  def user_skill_factory do
    %Vutuv.Profiles.UserSkill{}
  end

  def connection_factory do
    %Vutuv.Social.Connection{}
  end

  def group_factory do
    %Vutuv.Social.Group{
      name: sequence(:group_name, &"Group #{&1}")
    }
  end

  def membership_factory do
    %Vutuv.Social.Membership{}
  end

  def tag_factory do
    %Vutuv.Tags.Tag{
      name: sequence(:tag_name, &"Tag Name #{&1}"),
      slug: sequence(:tag_slug, &"tag-#{&1}")
    }
  end

  def user_tag_factory do
    %Vutuv.Tags.UserTag{}
  end

  def user_tag_endorsement_factory do
    %Vutuv.Tags.UserTagEndorsement{}
  end

  def endorsement_factory do
    %Vutuv.Profiles.Endorsement{}
  end

  def job_posting_factory do
    %Vutuv.JobPostings.JobPosting{
      title: sequence(:job_title, &"Job #{&1}"),
      slug: sequence(:job_slug, &"job-#{&1}"),
      open_on: ~D[2025-01-01],
      closed_on: ~D[2025-12-31]
    }
  end

  def job_posting_tag_factory do
    %Vutuv.JobPostings.JobPostingTag{
      priority: 1
    }
  end

  def recruiter_package_factory do
    %Vutuv.Recruiting.RecruiterPackage{
      name: "Basic Package",
      description: "A basic recruiting package",
      slug: sequence(:package_slug, &"package-#{&1}"),
      price: 99.99,
      currency: "euro",
      duration_in_months: 12,
      auto_renewal: true,
      offer_begins: ~D[2025-01-01],
      offer_ends: ~D[2025-12-31],
      max_job_postings: 5,
      only_with_coupon: false
    }
  end

  def recruiter_subscription_factory do
    %Vutuv.Recruiting.RecruiterSubscription{
      subscription_begins: ~D[2025-01-01],
      subscription_ends: ~D[2025-12-31],
      line1: "Acme Corp",
      zip_code: "10115",
      city: "Berlin",
      country: "Germany"
    }
  end

  def coupon_factory do
    %Vutuv.Recruiting.Coupon{
      code: sequence(:coupon_code, &String.slice("ABCDEFGH#{&1}KLMNPRST", 0, 8)),
      percentage: 10,
      ends_on: Date.add(Date.utc_today(), 30),
      valid: true
    }
  end

  def o_auth_provider_factory do
    %Vutuv.Accounts.OAuthProvider{
      provider: "google",
      provider_id: sequence(:provider_id, &"google-id-#{&1}")
    }
  end
end
