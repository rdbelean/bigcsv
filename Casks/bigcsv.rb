cask "bigcsv" do
  version "1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/rdbelean/bigcsv/releases/download/v#{version}/BigCSV-#{version}.dmg",
      verified: "github.com/rdbelean/bigcsv/"
  name "BigCSV"
  desc "Open multi-gigabyte CSV/TSV files instantly on macOS"
  homepage "https://bigcsv.app/"

  depends_on macos: ">= :sonoma"

  app "BigCSV.app"

  zap trash: [
    "~/Library/Containers/com.rdb.bigcsv",
    "~/Library/Preferences/com.rdb.bigcsv.plist",
  ]
end
