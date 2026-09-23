#!/usr/bin/env ruby
# Add bones to an Empire .anim JSON (from anim2json_etw).
#
#   ruby anim_addbone.rb in.json out.json "Name:parentIndex" ["Name2:parent" ...]
#
# Each frame holds one entry per bone: [ [4 rotation floats], [8 translation/
# scale floats] ]. A new bone is seeded by COPYING ITS PARENT'S ENTRY, which
# places it exactly at the parent's origin - visually identical to the parent
# joint, so nothing moves until motion is authored. That is deliberate: it makes
# the skeleton change provable in isolation from the animation change.
require "json"

src, dst, *specs = ARGV
abort("usage: anim_addbone.rb in.json out.json Name:parent [...]") if specs.empty?

j = JSON.parse(File.read(src))
bones  = j["bones"]
frames = j["frames"]
before = bones.size

specs.each do |spec|
  name, parent = spec.split(":")
  parent = parent.to_i
  abort("parent #{parent} out of range for #{name} (have #{bones.size} bones)") if parent < 0 || parent >= bones.size
  abort("duplicate bone name #{name}") if bones.any? { |n, _| n == name }
  bones << [name, parent]
  frames.each { |f| f << Marshal.load(Marshal.dump(f[parent])) }
end

# every frame must still carry exactly one entry per bone
frames.each_with_index do |f, i|
  abort("frame #{i} has #{f.size} entries, expected #{bones.size}") unless f.size == bones.size
end

File.write(dst, JSON.pretty_generate(j))
puts "#{before} -> #{bones.size} bones, #{frames.size} frames all consistent"
specs.each { |s| n, p = s.split(":"); puts "   + %-22s parent %s (%s)" % [n, p, bones[p.to_i][0]] }
