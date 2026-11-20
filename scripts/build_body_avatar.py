"""Build BodyAvatar.usdz from the pinned CC0 MakeHuman hm08 OBJ.

Usage: python3 scripts/build_body_avatar.py base.obj ios/EtoTy/BodyAvatar.usdz
Requires NumPy. See docs/plan/avatar-asset.md for the source and license.
"""
import hashlib
import math
import struct
import sys
import zipfile
from pathlib import Path

import numpy as np


if len(sys.argv) != 3:
    raise SystemExit(__doc__)
source = Path(sys.argv[1]).read_bytes()
if hashlib.sha256(source).hexdigest() != "8e761e6624b8f54536409135d1636da63b32486a90d4897f84e121d144f6fb4c":
    raise SystemExit("Unexpected base.obj. See docs/plan/avatar-asset.md.")

vertices = []
faces = []
group = ""
for line in source.decode().splitlines():
    if line.startswith("v "):
        vertices.append(tuple(map(float, line.split()[1:4])))
    elif line.startswith("g "):
        group = line.split()[1]
    elif group == "body" and line.startswith("f "):
        faces.append([int(t.split("/")[0]) - 1 for t in line.split()[1:]])
v = np.asarray(vertices)
assert len(faces) == 13378

# Lower the forearms towards the sides and soften the spread of the legs.
for p in v:
    x, y, z = p
    arm = np.clip((abs(x)-1.84)/.60, 0, 1) * np.clip((5.9-y)/.8,0,1) if y > 1.1 else 0
    if arm:
        side = np.sign(x)
        dx, dy = abs(x)-1.78, y-5.25
        a = -.31*arm
        p[0] = side*(1.78+math.cos(a)*dx-math.sin(a)*dy)
        p[1] = 5.25+math.sin(a)*dx+math.cos(a)*dy
        p[2] -= .50*arm*np.clip((4.5-y)/2.8,0,1)
    if y < 0:
        p[0] -= np.sign(x)*.57*np.clip(-y/7,0,1)

colors = {
    "shell": (.48,.68,.77,.34), "skin": (.74,.54,.43,1), "hair": (.14,.095,.073,1),
    "eye": (.87,.87,.80,1), "iris": (.09,.16,.17,1), "pupil": (.025,.037,.045,1),
    "heart": (.90,.25,.24,1), "liver": (.66,.33,.25,1), "kidneys": (.70,.32,.46,1),
    "lung": (.45,.58,.72,.32), "artery": (.76,.28,.28,1), "vein": (.33,.49,.66,1)
}
parts = []


def mesh(name, points, polygons, material):
    # Reindex only the vertices belonging to this part. Calculate smooth vertex normals.
    ids = sorted({i for poly in polygons for i in poly})
    lookup = {old: i for i, old in enumerate(ids)}
    p = (np.asarray(points)[ids] - [0,-8.1676,.45]) * .1
    polys = [[lookup[i] for i in poly] for poly in polygons]
    normals = np.zeros_like(p)
    for poly in polys:
        normal = np.cross(p[poly[1]]-p[poly[0]], p[poly[-1]]-p[poly[0]])
        normals[poly] += normal
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-10)
    parts.append((name, p, polys, normals, material))


head, body, hair = [], [], []
for f in faces:
    x, y, z = v[f].mean(0)
    (head if y > 6.0 else body).append(f)
    front = np.clip((z-.07)/1.20,0,1)
    if y > 6.90 + .97*front + .09*x + .045*math.sin(4*x):
        hair.append(f)
mesh("Shell", v, body, "shell")
mesh("Face", v, head, "skin")
scalp = v.copy()
for p in scalp:
    x, y, z = p
    n = np.array([x, (y-7.46)*.8, z-.56])
    n /= max(np.linalg.norm(n),.01)
    crown = np.clip(y-7.4,0,1)
    t = math.atan2(x,z-.56)
    wave = .035*math.cos(13*t+2*(y-7))
    p += n*(.065+.085*crown + wave)
    p[1] += .115*crown
mesh("Hair", scalp, hair, "hair")


def surface(name, material, fn, rings=14, sides=24):
    points = [fn(0.,0.)]
    for i in range(1,rings):
        for j in range(sides):
            points.append(fn(i/rings,2*math.pi*j/sides))
    points.append(fn(1.,0.))

    def ring(i, j):
        return 1+(i-1)*sides+j%sides

    polys = []
    for j in range(sides):
        polys.append([0,ring(1,j+1),ring(1,j)])
        for i in range(1,rings-1):
            polys.append([ring(i,j),ring(i,j+1),ring(i+1,j+1),ring(i+1,j)])
        polys.append([ring(rings-1,j),ring(rings-1,j+1),len(points)-1])
    mesh(name, points, polys, material)


def ball(t, a):
    return np.array([math.sin(math.pi*t)*math.cos(a), math.cos(math.pi*t), math.sin(math.pi*t)*math.sin(a)])


def ellipsoid(name, mat, center, radii):
    surface(name, mat, lambda t, a: center+ball(t,a)*radii, rings=12, sides=20)


for side in (-1,1):
    end = "Left" if side>0 else "Right"
    c = np.array([side*.308,7.284,1.246])
    ellipsoid("Eye"+end,"eye",c,[.139,.136,.149])
    ellipsoid("Iris"+end,"iris",c+[0,0,.143],[.060,.063,.012])
    ellipsoid("Pupil"+end,"pupil",c+[0,0,.153],[.029,.030,.007])

    def brow(t,a):
        return (side*(.14+.38*t),7.46+.074*math.sin(math.pi*t)+.027*math.sin(a)*math.sin(math.pi*t),
                1.395-.11*t+.023*math.cos(a)*math.sin(math.pi*t))

    surface("Brow"+end, "hair", brow, rings=12, sides=8)


def heart(t,a):
    x,y,z = ball(t,a)
    taper = 1-.42*max(0,-y)
    return [.25+.58*x*taper-.28*y,3.98+.76*y-.075*x, .73+.54*z*taper+.08*y]


def liver(t,a):
    x,y,z = ball(t,a)
    width = 1-.57*max(x,0)
    return [-.37+1.29*x,2.87+.54*y*width+.15*x+.08*z, .53+.67*z*width-.09*x]


surface("Heart","heart",heart)
surface("Liver","liver",liver)
for side in (-1,1):
    def kidney(t,a):
        x,y,z = ball(t,a)
        notch = .20*math.exp(-((y-.08)/.32)**2)*max(0,-x)**2
        return [side*(.74+.33*x+.09*y+notch),2.22+.55*y+.14*(side>0),.01+.32*z]

    surface("Kidney"+("Left" if side>0 else "Right"),"kidneys",kidney)

    def lung(t,a):
        x,y,z = ball(t,a)
        spread = 1-.39*y
        return [side*(.86+.49*x*spread-.16*y),4.27+.94*y,.45+.57*z*spread]

    surface("Lung"+("Left" if side>0 else "Right"),"lung",lung)


def vessel(name, mat, path, radius):
    p = np.asarray(path)
    vertices, polys, count = [], [], 10
    for i, center in enumerate(p):
        tangent = p[min(i+1,len(p)-1)]-p[max(i-1,0)]
        tangent = tangent/np.linalg.norm(tangent)
        axis = np.cross(tangent,[0,0,1])
        axis /= np.linalg.norm(axis)
        axis2 = np.cross(tangent,axis)
        for j in range(count):
            a = 2*math.pi*j/count
            vertices.append(center+radius*(axis*math.cos(a)+axis2*math.sin(a)))
    for i in range(len(p)-1):
        for j in range(count):
            k = (j+1)%count
            polys.append([count*i+j,count*i+k,count*(i+1)+k,count*(i+1)+j])
    polys.extend([list(reversed(range(count))),list(range(len(vertices)-count,len(vertices)))])
    mesh(name,vertices,polys,mat)


vessel("AorticArch","artery",[[.07,4.36,.93],[-.06,4.62,.9],[-.04,4.84,.81],[.10,4.93,.66],[.24,4.83,.51],[.27,4.58,.46]],.11)
vessel("PulmonaryTrunk","vein",[[.36,4.29,1.02],[.33,4.49,1.05],[.41,4.65,.96],[.61,4.71,.79]],.093)


def vector(p):
    return '('+','.join(f'{x:.5f}'.rstrip('0').rstrip('.') or '0' for x in p)+')'


usd = ['#usda 1.0','(defaultPrim = "Avatar"',' metersPerUnit = 1',' upAxis = "Y")','def Xform "Avatar" {','def Scope "Looks" {']
for mat, (r,g,b,alpha) in colors.items():
    path = '/Avatar/Looks/'+mat+'/Surface'
    usd.extend([f'def Material "{mat}" {{',f'token outputs:surface.connect = <{path}.outputs:surface>',
      'def Shader "Surface" {','uniform token info:id = "UsdPreviewSurface"',
      'color3f inputs:diffuseColor = '+vector([r,g,b]),f'float inputs:opacity = {alpha}',
      'float inputs:roughness = 0.53','token outputs:surface','}','}'])
usd.append('}')
for name,p,polys,n,mat in parts:
    usd.extend([f'def Mesh "{name}" (prepend apiSchemas = ["MaterialBindingAPI"]) {{',
      f'rel material:binding = </Avatar/Looks/{mat}>','uniform token subdivisionScheme = "none"',
      'float3[] extent = ['+vector(p.min(0))+','+vector(p.max(0))+']',
      'point3f[] points = ['+','.join(map(vector,p))+']',
      'normal3f[] normals = ['+','.join(map(vector,n))+'] (interpolation = "vertex")',
      'int[] faceVertexCounts = ['+','.join(str(len(f)) for f in polys)+']',
      'int[] faceVertexIndices = ['+','.join(str(i) for f in polys for i in f)+']','}'])
usd.append('}')

# USDZ requires stored entries with 64-byte-aligned payloads.
entry = zipfile.ZipInfo("Avatar.usda")
padding = (-(30+len(entry.filename)+4))%64
entry.extra = struct.pack("<HH",0xffff,padding)+bytes(padding)
with zipfile.ZipFile(sys.argv[2],"w",compression=zipfile.ZIP_STORED) as package:
    package.writestr(entry,'\n'.join(usd)+'\n')
