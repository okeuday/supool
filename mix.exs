defmodule Supool.Mixfile do
  use Mix.Project

  def project do
    [app: :supool,
     version: "1.5.3",
     description: description,
     package: package,
     deps: deps]
  end

  defp deps do
    []
  end

  defp description do
    "Erlang Process Pool as a Supervisor"
  end

  defp package do
    [files: ~w(src doc test rebar.config README.markdown),
     maintainers: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"GitHub" => "https://github.com/okeuday/supool"}]
   end
end
