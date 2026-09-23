# vwm_blender.py - import/export Empire unit meshes in Blender, via the JSON
# produced by tools/vwm_json.rb.
#
# Phase 4 of ROADMAP_HIGH_POLY_UNITS.md. The chain is:
#
#     .variant_weighted_mesh  <->  JSON  <->  Blender
#           vwm_json.rb              this file
#
# Run headless (no GUI needed, and this is how it is TESTED):
#     blender --background --python vwm_blender.py -- import <in.json>  <out.blend>
#     blender --background --python vwm_blender.py -- export <in.blend> <out.json>
#     blender --background --python vwm_blender.py -- roundtrip <in.json> <out.json>
#
# THE GATE
#   JSON -> Blender -> JSON must come back byte-identical for an unmodified
#   mesh, the same standard the format and the JSON layer already meet. A 3D
#   tool that silently perturbs vertices is worse than no tool at all, because
#   the damage only shows up in game.
#
# THE AWKWARD PART, AND HOW IT IS NOW SOLVED
#   Empire stores geometry in BONE SPACE: each vertex carries one position per
#   influencing bone, expressed relative to that bone, plus a normal and a
#   weight. Blender wants ONE position per vertex in object space plus a weight
#   per bone group.
#
#   Converting between the two needs the pose the mesh was authored in. That
#   pose has been RECOVERED - not from the .anim, but from the shipped geometry
#   itself, because every influence of a vertex stores the same world point in
#   a different bone's frame, so the bones' relative transforms fall out of the
#   meshes exactly (see tools/vwm_pose.rb and tools/vwm_pose_global.rb).
#
#   So `vwm_json.rb` now writes a real object-space position per vertex, and
#   this importer builds the mesh from it. Move a vertex here, export, and the
#   Ruby side converts the new position back into every bone's frame.
#
#   WHAT THIS IMPORTER DELIBERATELY DOES NOT WRITE BACK
#   Normals. Blender recomputes them from the surface, and they would not match
#   Empire's authored normals, so writing them back would rewrite every vertex
#   in the file and destroy the byte-identical round trip for no benefit. The
#   authored normals are carried through untouched.

import bpy, json, sys, os

MARK = "empire_vwm"

def argv():
    a = sys.argv
    return a[a.index("--") + 1:] if "--" in a else []

# --------------------------------------------------------------- import ----
def do_import(path):
    with open(path, "r") as fh:
        doc = json.load(fh)

    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)

    root = bpy.data.objects.new("empire_mesh", None)
    bpy.context.collection.objects.link(root)
    # The whole document rides along, so anything this importer does not model
    # is still present at export. Unknown data is preserved, never invented.
    root[MARK] = json.dumps(doc)

    posed = sum(1 for p in doc["parts"] for v in p["vertices"] if "obj" in v)
    total = sum(len(p["vertices"]) for p in doc["parts"])
    if posed < total:
        print("WARNING: %d of %d vertices have no object-space position and are "
              "shown in bone space; edits to them will not be written back"
              % (total - posed, total))

    for pi, part in enumerate(doc["parts"]):
        verts = []
        for v in part["vertices"]:
            p = v.get("obj")
            if p is None:
                # No pose for this vertex's bone. Shown where its first
                # influence puts it, which is NOT its real place - flagged
                # above, and the exporter refuses to convert it back.
                p = v["infl"][0]["pos"]
            verts.append((float(p[0]), float(p[1]), float(p[2])))

        idx = part["indices"]
        faces = [tuple(idx[i:i + 3]) for i in range(0, len(idx), 3)]

        me = bpy.data.meshes.new(part["name"])
        me.from_pydata(verts, [], faces)
        me.update()

        ob = bpy.data.objects.new(part["name"], me)
        ob.parent = root
        bpy.context.collection.objects.link(ob)
        ob["vwm_part_index"] = pi

        # UVs are real and directly useful - they are an atlas lookup
        if me.loops:
            uvl = me.uv_layers.new(name="UVMap")
            for loop in me.loops:
                uv = part["vertices"][loop.vertex_index]["uv"]
                uvl.data[loop.index].uv = (float(uv[0]), float(uv[1]))

        # one vertex group per bone actually used, so weights are visible
        groups = {}
        for vi, v in enumerate(part["vertices"]):
            for inf in v["infl"]:
                b = inf["bone"]
                if b not in groups:
                    groups[b] = ob.vertex_groups.new(name="bone_%d" % b)
                groups[b].add([vi], float(inf["weight"]), 'REPLACE')

    print("imported %d parts, %d vertices" %
          (len(doc["parts"]), sum(len(p["vertices"]) for p in doc["parts"])))
    return doc

# --------------------------------------------------------------- export ----
def do_export(path):
    root = next((o for o in bpy.data.objects if MARK in o.keys()), None)
    if root is None:
        raise SystemExit("no empire_vwm object in this scene - import one first")
    doc = json.loads(root[MARK])

    # Objects are matched by the index stamped at import, not by name, so
    # renaming a part in Blender does not silently write it to the wrong slot.
    by_index = {}
    for o in bpy.data.objects:
        if o.type == 'MESH' and "vwm_part_index" in o.keys():
            by_index[int(o["vwm_part_index"])] = o

    moved = 0
    for pi, part in enumerate(doc["parts"]):
        ob = by_index.get(pi)
        if ob is None:
            raise SystemExit("part %d (%s) is missing from the scene - refusing "
                             "to export a partial mesh" % (pi, part["name"]))
        verts = part["vertices"]
        if len(ob.data.vertices) != len(verts):
            # Adding or removing geometry needs UVs, weights and influences for
            # the new vertices, which Blender cannot invent. Refuse rather than
            # write something that looks plausible.
            raise SystemExit(
                "part %d (%s): vertex count changed %d -> %d. Adding or removing "
                "geometry is not supported yet - move vertices, do not create them."
                % (pi, part["name"], len(verts), len(ob.data.vertices)))
        for vi, bv in enumerate(ob.data.vertices):
            v = verts[vi]
            if "obj" not in v:
                continue                 # no pose; leave the carried data alone
            co = (float(bv.co[0]), float(bv.co[1]), float(bv.co[2]))
            if co != tuple(float(c) for c in v["obj"]):
                v["obj"] = list(co)
                moved += 1

    with open(path, "w") as fh:
        json.dump(doc, fh, indent=1)
    print("exported %d parts, %d vertices moved" % (len(doc["parts"]), moved))

# ------------------------------------------------------------- move test ----
# THE GATE FOR EDITING, as opposed to the gate for viewing.
#   Import, move exactly one vertex IN BLENDER, export. The Ruby side must then
#   rewrite that vertex in every bone's frame and leave the rest of the file
#   untouched. Without this, "you can model in Blender" is an assumption.
def do_movetest(inp, outp, dx=0.05):
    do_import(inp)
    ob = next(o for o in bpy.data.objects
              if o.type == 'MESH' and len(o.data.vertices) > 0)
    v = ob.data.vertices[0]
    before = tuple(v.co)
    v.co[0] += dx
    print("moved %s vertex 0: %s -> %s" % (ob.name, before, tuple(v.co)))
    do_export(outp)

def main():
    a = argv()
    if not a:
        print("usage: -- import|export|roundtrip|movetest <in> [out]"); return
    mode = a[0]
    if mode == "import":
        do_import(a[1])
        if len(a) > 2:
            bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(a[2]))
    elif mode == "export":
        bpy.ops.wm.open_mainfile(filepath=os.path.abspath(a[1]))
        do_export(a[2])
    elif mode == "roundtrip":
        do_import(a[1])
        do_export(a[2])
    elif mode == "movetest":
        do_movetest(a[1], a[2], float(a[3]) if len(a) > 3 else 0.05)
    else:
        print("unknown mode: %s" % mode)

main()
