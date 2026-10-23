const L=require('./icons.js');
const ids=Object.keys(L.D);
function circ(cx,cy,r){return `M${cx-r} ${cy}a${r} ${r} 0 1 0 ${2*r} 0a${r} ${r} 0 1 0 ${-2*r} 0z`;}
function rect(x,y,w,h,r){r=r||0;return `M${x+r} ${y}H${x+w-r}a${r} ${r} 0 0 1 ${r} ${r}V${y+h-r}a${r} ${r} 0 0 1 ${-r} ${r}H${x+r}a${r} ${r} 0 0 1 ${-r} ${-r}V${y+r}a${r} ${r} 0 0 1 ${r} ${-r}z`;}
const ink=v=>v==='$L'?'.line':v==='$A'?'.accent':'.none';
function parse(id){
  const g=L.glyph(id,'$L','$A');
  const els=[];
  const re=/<(path|circle|rect)\b([^>]*?)\/>/g; let m;
  while((m=re.exec(g))){
    const attrs={}; const ar=/([\w-]+)="([^"]*)"/g; let a;
    while((a=ar.exec(m[2]))) attrs[a[1]]=a[2];
    let d;
    if(m[1]==='path') d=attrs.d;
    else if(m[1]==='circle') d=circ(+attrs.cx,+attrs.cy,+attrs.r);
    else d=rect(+attrs.x,+attrs.y,+attrs.width,+attrs.height,+(attrs.rx||0));
    const fill=attrs.fill===undefined?'none':attrs.fill;
    const stroke=attrs.stroke===undefined?'$L':attrs.stroke;
    const sw=attrs['stroke-width']===undefined?2.6:+attrs['stroke-width'];
    const dash=attrs['stroke-dasharray']?attrs['stroke-dasharray'].split(/\s+/).map(Number):[];
    const op=attrs.opacity===undefined?1:+attrs.opacity;
    els.push({d,fill:ink(fill),stroke:ink(stroke),sw,dash,op});
  }
  return els;
}
let out=`// GENERATED from the approved icon sheets. Do not edit by hand.
// Each glyph is the "content" drawn inside the page (lines, mountains, play buttons, waveforms...)
// on a 64x64 grid. \`line\` = quiet ink, \`accent\` = the format's colour.
import CoreGraphics

enum IconInk { case none, line, accent }

struct IconEl {
    let d: String
    let fill: IconInk
    let stroke: IconInk
    let width: CGFloat
    let dash: [CGFloat]
    let opacity: CGFloat
}

private func E(_ d: String, _ fill: IconInk, _ stroke: IconInk, _ width: CGFloat,
               _ dash: [CGFloat] = [], _ opacity: CGFloat = 1) -> IconEl {
    IconEl(d: d, fill: fill, stroke: stroke, width: width, dash: dash, opacity: opacity)
}

enum IconData {
    static let glyphs: [String: [IconEl]] = build()

    private static func build() -> [String: [IconEl]] {
        var g: [String: [IconEl]] = [:]
`;
for(const id of ids){
  const els=parse(id);
  if(!els.length && !['unpack'].includes(id)) console.error('no glyph for',id);
  out+=`        g["${id}"] = [\n`;
  for(const e of els){
    out+=`            E("${e.d}", ${e.fill}, ${e.stroke}, ${e.sw}${e.dash.length||e.op!==1?`, [${e.dash.join(', ')}]`:''}${e.op!==1?`, ${e.op}`:''}),\n`;
  }
  out+=`        ]\n`;
}
out+=`        return g\n    }\n}\n`;
require('fs').writeFileSync('IconData.swift',out);
console.log(out.split('\n').length,'lines');
// also dump parsed json for verification
require('fs').writeFileSync('glyphs.json',JSON.stringify(Object.fromEntries(ids.map(i=>[i,parse(i)]))));
