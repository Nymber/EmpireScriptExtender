# empire_paths.rb - locate an Empire: Total War install on ANY machine.
#
# Ruby twin of empire_paths.ps1, same resolution order, no PowerShell needed:
#   1. ENV["EMPIRE_DIR"]        - explicit override, always wins
#   2. Steam registry -> libraryfolders.vdf -> appmanifest_10500.acf
#   3. common fallback paths
#   4. walk up from __FILE__     - the tools live inside the install, so if all
#                                  else fails the answer is above us
#
# Usage from any tool in this repo:
#   require_relative "empire_paths"      # adjust depth as needed
#   EMPIRE.game    # install dir
#   EMPIRE.data    # data/ (the .pack files)
#   EMPIRE.pack("patch.pack")
#
# Run directly to print what it found:
#   ruby empire_paths.rb

require "pathname"

module EmpirePaths
  APP_ID = 10500

  module_function

  def registry_steam_roots
    roots = []
    # Reading the registry without a gem: reg.exe is always present on Windows.
    [
      'HKCU\Software\Valve\Steam',
      'HKLM\SOFTWARE\WOW6432Node\Valve\Steam',
      'HKLM\SOFTWARE\Valve\Steam'
    ].each do |key|
      %w[SteamPath InstallPath].each do |val|
        out = `reg query "#{key}" /v #{val} 2>nul`
        next unless $?.success?
        if out =~ /REG_SZ\s+(.+)/
          p = $1.strip.tr("\\", "/")
          roots << p if File.directory?(p)
        end
      end
    end
    roots.uniq
  end

  def steam_exe
    env = ENV["STEAM_EXE"]
    return File.expand_path(env) if env && File.exist?(env)
    registry_steam_roots.each do |root|
      exe = File.join(root, "steam.exe")
      return File.expand_path(exe) if File.exist?(exe)
    end
    nil
  end

  def steam_libraries
    libs = registry_steam_roots
    libs.dup.each do |root|
      vdf = File.join(root, "steamapps/libraryfolders.vdf")
      next unless File.exist?(vdf)
      # Each library block carries a "path" line; full VDF parsing is overkill.
      File.read(vdf).scan(/"path"\s+"(.+?)"/) do |m|
        p = m[0].gsub('\\\\', "/").tr("\\", "/")
        libs << p if File.directory?(p)
      end
    end
    libs.uniq
  end

  def find_game_dir
    env = ENV["EMPIRE_DIR"]
    return File.expand_path(env) if env && File.exist?(File.join(env, "Empire.exe"))

    steam_libraries.each do |lib|
      acf = File.join(lib, "steamapps/appmanifest_#{APP_ID}.acf")
      if File.exist?(acf) && File.read(acf) =~ /"installdir"\s+"(.+?)"/
        d = File.join(lib, "steamapps/common", $1)
        return File.expand_path(d) if File.exist?(File.join(d, "Empire.exe"))
      end
      d = File.join(lib, "steamapps/common/Empire Total War")
      return File.expand_path(d) if File.exist?(File.join(d, "Empire.exe"))
    end

    [
      "C:/Program Files (x86)/Steam/steamapps/common/Empire Total War",
      "C:/Program Files/Steam/steamapps/common/Empire Total War",
      "C:/Program Files (x86)/SEGA/Empire Total War"
    ].each { |d| return d if File.exist?(File.join(d, "Empire.exe")) }

    # These tools live inside the install, so walk up looking for Empire.exe.
    here = Pathname.new(File.expand_path(__FILE__)).dirname
    here.ascend do |dir|
      return dir.to_s if File.exist?(File.join(dir.to_s, "Empire.exe"))
    end

    nil
  end

  # Where this KIT is checked out, independent of where the game is. This file
  # lives at the kit root, so the kit is its own directory - and the wider tools
  # folder is the parent. Deriving either from the game path assumed the kit is
  # unzipped inside the Steam install; it can sit anywhere.
  KIT = File.dirname(File.expand_path(__FILE__))

  class Paths
    attr_reader :game

    def initialize(game)
      @game = game
    end

    def exe       = File.join(@game, "Empire.exe")
    def data      = File.join(@game, "data")
    # The TOOLKIT root is where THIS file lives - NOT a subfolder of the game.
    # Deriving it from @game assumed the tools are unzipped inside the Steam
    # install; a release can sit anywhere, and the game can be on another drive.
    # kit   - this toolkit (EmpireScriptExtender), the release unit.
    # tools - its PARENT, which also holds SaveParser, RPFM and Ghidra, so the
    #         two are NOT interchangeable.
    def kit          = KIT
    def tools        = File.dirname(KIT)
    def script_tools = File.join(KIT, "tools")
    # The game reads its own mirrored copy; 'empire.ps1 sync' fills it.
    def game_kit     = File.join(@game, "EmpireScriptExtender")
    # The ESE source, build script, ese.ps1 and launch_battle.ps1 live in src.
    # (This was "ESE" until that folder was removed on 2026-09-22.)
    def ese          = File.join(KIT, "src")
    def dll       = File.join(@game, "dinput8.dll")
    def ese_log   = File.join(@game, "ese_log.txt")
    def user      = File.join(ENV["APPDATA"].to_s.tr("\\", "/"), "The Creative Assembly/Empire")
    def steam_exe = EmpirePaths.steam_exe
    def prefs     = File.join(user, "scripts/preferences.empire_script.txt")
    def fx_cache  = File.join(user, "fx_cache")
    def pack(name) = File.join(data, name)

    def to_h
      { game: game, data: data, kit: kit, tools: tools,
        script_tools: script_tools, ese: ese, game_kit: game_kit,
        dll: dll, ese_log: ese_log, steam_exe: steam_exe,
        user: user, prefs: prefs, fx_cache: fx_cache }
    end
  end
end

_game = EmpirePaths.find_game_dir
raise "Empire: Total War not found. Set EMPIRE_DIR to the folder containing Empire.exe." unless _game
EMPIRE = EmpirePaths::Paths.new(_game)

if __FILE__ == $0
  EMPIRE.to_h.each { |k, v| puts format("  %-9s %s %s", k, File.exist?(v) ? "ok" : "--", v) }
end
