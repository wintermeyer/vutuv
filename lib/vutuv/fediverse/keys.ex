defmodule Vutuv.Fediverse.Keys do
  @moduledoc """
  RSA keypairs for Fediverse actors.

  Every federating member gets a 2048-bit RSA pair (created lazily on opt-in):
  the private key signs outbound deliveries (`Vutuv.Fediverse.HttpSignature`),
  the public key is published in the actor document. RSA/SHA-256 because that
  is the one algorithm the whole Fediverse (Mastodon first) accepts; the
  public PEM is SubjectPublicKeyInfo ("BEGIN PUBLIC KEY"), the form Mastodon
  emits and expects.
  """

  @doc "A fresh {private_pem, public_pem} pair."
  def generate do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _vsn, n, e, _d, _p, _q, _e1, _e2, _c, _o} = key

    private_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    public_pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, n, e})
      ])

    {private_pem, public_pem}
  end

  @doc "Decodes a PEM (private or public) into the :public_key record."
  def decode_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry] -> {:ok, :public_key.pem_entry_decode(entry)}
      _other -> {:error, :invalid_pem}
    end
  end
end
