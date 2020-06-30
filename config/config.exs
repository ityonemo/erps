if Mix.env == :test do
  Application.put_env(:erps, :use_multiverses, true)
end
