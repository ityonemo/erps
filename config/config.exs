import Config

if Mix.env == :test do
  config :erps, use_multiverses: true
end
