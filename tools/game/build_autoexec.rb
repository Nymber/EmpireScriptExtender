# Write the thin battle entry that loads the fp folder.
#
# This used to concatenate the part scripts into one fat file beside this
# script. That file was not what the game ran (ESE reads ese_battle_autoexec.lua
# from the install root), and a later run would have put the fat copy back.
# The parts live in EmpireScriptExtender/lua/fp/ and are loaded by fp/mod.lua.
#
# Do not strip `return` from those part files. Several returns are multi-line;
# dropping only the first line leaves an orphaned continuation.

here = File.dirname(File.expand_path(__FILE__))
install = File.expand_path('../../../..', here)
fp = File.expand_path('../../lua/fp', here)

parts = %w[fpsetup.lua fppick.lua fpdrive.lua walkdiff.lua fpctl.lua mod.lua]
parts.each do |f|
  abort("missing #{File.join(fp, f)}") unless File.exist?(File.join(fp, f))
end

# LF only. File.write on Windows otherwise emits CRLF, and the game-root copy
# (what ESE actually runs) would no longer match this one.
loader = File.read(File.join(install, 'ese_battle_autoexec.lua')).gsub("\r\n", "\n")
[File.join(install, 'ese_battle_autoexec.lua'), File.join(fp, 'ese_battle_autoexec.lua')].each do |dst|
  File.binwrite(dst, loader)
  puts "wrote #{dst} (#{loader.bytesize} bytes)"
end
puts "parts present: #{parts.join(' ')}"