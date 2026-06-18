defmodule Vutuv.PhoneTest do
  use ExUnit.Case, async: true

  alias Vutuv.Phone

  describe "national/2" do
    test "renders a German number in national format for de viewers (drops +49)" do
      assert Phone.national("+49 261 9886803", "de") == "0261 9886803"
      assert Phone.national("+49 30 5550100", "de") == "030 5550100"
      assert Phone.national("+4915142408756", "de") == "01514 2408756"
    end

    test "normalizes a German number stored without the +49 prefix for de viewers" do
      assert Phone.national("017629544122", "de") == "0176 29544122"
      assert Phone.national("0171-1783428", "de") == "0171 1783428"
    end

    test "leaves the value untouched for non-de viewers" do
      assert Phone.national("+49 261 9886803", "en") == "+49 261 9886803"
      assert Phone.national("+49 261 9886803", nil) == "+49 261 9886803"
    end

    test "never strips the country code off a foreign number, even for de viewers" do
      assert Phone.national("+421903419345", "de") == "+421903419345"
      assert Phone.national("+41 78 956 91 14", "de") == "+41 78 956 91 14"
    end

    test "falls back to the stored value when it cannot be parsed or validated" do
      assert Phone.national("not a phone", "de") == "not a phone"
      assert Phone.national("12", "de") == "12"
      assert Phone.national("", "de") == ""
    end
  end

  describe "tel/1" do
    test "returns the E.164 form for the tel: link" do
      assert Phone.tel("+49 261 9886803") == "+492619886803"
      assert Phone.tel("017629544122") == "+4917629544122"
      assert Phone.tel("+421903419345") == "+421903419345"
    end

    test "strips spaces and punctuation when the value cannot be parsed" do
      assert Phone.tel("abc") == ""
      assert Phone.tel("+49") == "+49"
    end
  end
end
