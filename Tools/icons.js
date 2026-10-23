/* ---------- DropWheel icon system: page + extension badge, 64x64 grid ---------- */
const FAM = {pdf:'#E5484D',doc:'#4C8DF6',data:'#2FB27A',image:'#F2764B',video:'#8F6BF2',audio:'#E5589E',archive:'#D9A21F'};
const D = {};
function def(id,fam,badge,label,verb){ D[id]={id,fam,badge,label:label||id.toUpperCase(),verb:verb||('Convert to '+id.toUpperCase())}; }
['jpg','png','heic','webp','tiff','gif','bmp'].forEach(i=>def(i,'image',i.toUpperCase()));
['mp4','mov','mkv','webm'].forEach(i=>def(i,'video',i.toUpperCase()));
['mp3','m4a','wav','aiff','flac','ogg'].forEach(i=>def(i,'audio',i.toUpperCase()));
['pdf','docx','odt','rtf','txt','md','html','epub'].forEach(i=>def(i,i==='pdf'?'pdf':'doc',i.toUpperCase()));
['xlsx','csv','json'].forEach(i=>def(i,'data',i.toUpperCase()));
def('zip','archive','ZIP','ZIP','Zip it up');
def('unpack','archive',null,'UNPACK','Unpack here');
def('sign','pdf','PDF','SIGN','Sign this document');
def('merge','pdf','PDF','MERGE','Merge into one PDF');
def('split','pdf','PDF','SPLIT','Split into pages');
def('compress','pdf','PDF','COMPRESS','Shrink the file size');
const TOOLS=['sign','merge','split','compress','unpack'];
const GROUPS=[
 ['Documents',['pdf','docx','odt','rtf','txt','md','html','epub']],
 ['Data',['xlsx','csv','json']],
 ['Images',['jpg','png','heic','webp','tiff','gif','bmp']],
 ['Video',['mp4','mov','mkv','webm']],
 ['Audio',['mp3','m4a','wav','aiff','flac','ogg']],
 ['Tools',['sign','merge','split','compress','zip','unpack']],
];

/* colour helpers */
function rgb(h){h=h.replace('#','');return [0,2,4].map(i=>parseInt(h.substr(i,2),16));}
function lum(h){const [r,g,b]=rgb(h).map(v=>{v/=255;return v<=.03928?v/12.92:Math.pow((v+.055)/1.055,2.4);});return .2126*r+.7152*g+.0722*b;}
function contrast(a,b){const l1=lum(a),l2=lum(b);return (Math.max(l1,l2)+.05)/(Math.min(l1,l2)+.05);}
function textOn(h){return contrast(h,'#ffffff')>=contrast(h,'#111111')?'#ffffff':'#111111';}
function shade(h,a){const c=rgb(h).map(v=>Math.round(a<0?v*(1+a):v+(255-v)*a));return '#'+c.map(v=>v.toString(16).padStart(2,'0')).join('');}

function baseColor(id,o){
  if(o.cmode==='mono') return o.theme==='dark'?'#EDEDED':'#2A2D33';
  if(o.cmode==='accent') return o.accent;
  return FAM[D[id].fam];
}
function badgeFor(c){
  if(lum(c)>.55) return {fill:c,text:'#111111'};
  let f=c,a=0;
  while(contrast(f,'#ffffff')<4.5 && a>-.7){a-=.04;f=shade(c,a);}
  return {fill:f,text:'#ffffff'};
}
function palette(id,o){
  const c=baseColor(id,o), dark=o.theme==='dark';
  const bg=dark?'#1c1c20':'#ffffff';
  const ink=dark?'rgba(255,255,255,.6)':'rgba(0,0,0,.5)';
  let p={c,bg};
  if(o.style==='outline'){Object.assign(p,{pageFill:dark?'#ffffff':'#000000',pageOp:dark?.04:.03,pageStroke:c,L:ink,A:c,bFill:badgeFor(c).fill,bText:badgeFor(c).text,bStroke:null,fold:c});}
  else if(o.style==='soft'){Object.assign(p,{pageFill:c,pageOp:.2,pageStroke:c,L:c,A:c,bFill:badgeFor(c).fill,bText:badgeFor(c).text,bStroke:null,fold:c});}
  else {const on=textOn(c);Object.assign(p,{pageFill:c,pageOp:1,pageStroke:'none',L:on==='#ffffff'?'rgba(255,255,255,.9)':'rgba(17,17,17,.78)',A:on,bFill:'#ffffff',bText:shade(c,-.55),bStroke:c,fold:'rgba(0,0,0,.28)'});}
  return p;
}

function pg(x0,x1,y0,y1,f,r){
  return {d:`M${x0+r} ${y0}H${x1-f}L${x1} ${y0+f}V${y1-r}a${r} ${r} 0 0 1-${r} ${r}H${x0+r}a${r} ${r} 0 0 1-${r}-${r}V${y0+r}a${r} ${r} 0 0 1 ${r}-${r}z`,
          fold:`M${x1-f} ${y0}v${f-r}a${r} ${r} 0 0 0 ${r} ${r}H${x1}`};
}

function glyph(id,L,A){
  const mtn='<path d="M23 34l8-10 6 7 4-4.5 7 7.5"/>';
  const G={
   pdf:`<path d="M23 15h24M23 21h24M23 27h24M23 33h15"/>`,
   docx:`<path d="M23 15h13" stroke="${A}" stroke-width="4"/><path d="M23 22h24M23 28h24M23 34h14"/>`,
   odt:`<path d="M23 15h24M23 21h24"/><circle cx="29.5" cy="30" r="4.3" stroke="${A}"/><path d="M38 28.5h9M38 33h6"/>`,
   rtf:`<path d="M23 15h13" stroke="${A}" stroke-width="4"/><path d="M23 22h24"/><path d="M23 28h24" stroke-dasharray="5 3.5"/><path d="M23 34h14"/>`,
   txt:`<path d="M23 15h24M23 21h24M23 27h24M23 33h18"/>`,
   md:`<path d="M23 29V16l5.5 7 5.5-7v13"/><path d="M42 16v12M38 24l4 4 4-4" stroke="${A}"/>`,
   html:`<path d="M29 17l-6 7 6 7M41 17l6 7-6 7"/><path d="M37 14.5l-4 19" stroke="${A}"/>`,
   epub:`<path d="M35 17c-4-2.6-9-2.6-12 0v15c3-2.6 8-2.6 12 0 4-2.6 9-2.6 12 0V17c-3-2.6-8-2.6-12 0z"/><path d="M35 17v15" stroke="${A}"/>`,
   xlsx:`<rect x="23" y="15" width="24" height="19" rx="2.5"/><path d="M23 28h24M31 15v19"/><path d="M23 21.5h24" stroke="${A}"/>`,
   csv:`<path d="M23 17h8M37 17h10M23 24h11M40 24h7M23 31h6M35 31h12"/><path d="M34 17h.01M37 24h.01M32 31h.01" stroke="${A}" stroke-width="4"/>`,
   json:`<path d="M29 14.5c-3.5 0-4.5 1.5-4.5 4.5v2.5c0 2-1 2.5-2.5 2.5 1.5 0 2.5.5 2.5 2.5V29c0 3 1 4.5 4.5 4.5M41 14.5c3.5 0 4.5 1.5 4.5 4.5v2.5c0 2 1 2.5 2.5 2.5-1.5 0-2.5.5-2.5 2.5V29c0 3-1 4.5-4.5 4.5"/><path d="M35 24h.01" stroke="${A}" stroke-width="4"/>`,
   zip:`<path d="M35 13v14M31.5 16.5h7M31.5 21.5h7"/><rect x="31" y="27" width="8" height="7" rx="2.2" stroke="${A}"/>`,
   jpg:`<circle cx="42" cy="19" r="2.8" fill="${A}" stroke="none"/>${mtn}`,
   png:`<rect x="38.5" y="14.5" width="9" height="9" rx="1.5" stroke-width="2"/><path d="M38.5 14.5h4.5v4.5h-4.5zM43 19h4.5v4.5H43z" fill="${A}" stroke="none"/><path d="M23 34l8-10 6 7 3-3.5 7 6.5"/>`,
   heic:`<circle cx="42" cy="19" r="2.2" fill="${A}" stroke="none"/><circle cx="42" cy="19" r="5.4" stroke="${A}" stroke-width="1.8" opacity=".7"/>${mtn}`,
   webp:`<circle cx="41.5" cy="19.5" r="5" stroke="${A}" stroke-width="2"/><path d="M36.5 19.5h10M41.5 14.5c-2.4 2.8-2.4 7.2 0 10M41.5 14.5c2.4 2.8 2.4 7.2 0 10" stroke="${A}" stroke-width="1.7"/>${mtn}`,
   tiff:`<path d="M26 14.5h18M24 19h22" stroke="${A}" stroke-width="2" opacity=".8"/><path d="M23 34l7-7.5 5 5.5 3.5-3.5 9.5 5.5"/>`,
   gif:`<path d="M35 17a7 7 0 1 1-7 7" stroke="${A}"/><path d="M25 27l3-3 3 3" stroke="${A}"/><circle cx="35" cy="24" r="1.9" fill="${A}" stroke="none"/>`,
   bmp:`<path d="M23 34v-4h4v-4h4v-4h4v4h4v4h4v4"/><path d="M41 15h4v4h-4z" fill="${A}" stroke="none"/>`,
   mp4:`<rect x="23" y="14" width="24" height="20" rx="4"/><path d="M32 19.5v9l8-4.5z" fill="${A}" stroke="${A}" stroke-width="1.6"/>`,
   mov:`<rect x="23" y="20" width="24" height="14" rx="2.5"/><path d="M23 20l-.6-4.8 24.2-3.9.7 4.8z"/><path d="M29.5 19l-.9-5.6M36 17.9l-.9-5.6M42.5 16.9l-.9-5.6" stroke="${A}"/><path d="M32.5 24.5v6l5-3z" fill="${A}" stroke="${A}" stroke-width="1.4"/>`,
   mkv:`<rect x="23" y="14" width="24" height="20" rx="4"/><path d="M28 19.5v9l6-4.5z" fill="${A}" stroke="${A}" stroke-width="1.4"/><path d="M38 19h5M38 24h5M38 29h5" stroke="${A}"/>`,
   webm:`<rect x="23" y="14" width="24" height="20" rx="4"/><path d="M31 18.5v8l7-4z" fill="${A}" stroke="${A}" stroke-width="1.4"/><path d="M27 30.5h10" stroke="${A}" stroke-width="2.2"/><path d="M41 30.5h.01" stroke="${A}" stroke-width="3.6"/>`,
   mp3:`<path d="M25 21v6M30 17v14M35 14v20M40 18v12M45 21v6" stroke="${A}" stroke-width="3.4"/>`,
   wav:`<path d="M23 24h3l2-6 3 12 3-16 3 20 3-12 2 2h3" stroke="${A}"/>`,
   aiff:`<path d="M23 29h5v-10h5v14h5v-12h5v8h4" stroke="${A}"/>`,
   flac:`<path d="M35 13l3.6 3.6L35 20.2l-3.6-3.6z" fill="${A}" stroke="none"/><path d="M23 31h4l2-3 3 6 3-8 3 6 2-1.5h5" stroke="${A}"/>`,
   m4a:`<path d="M31 29V16l12-3v13" stroke="${A}"/><circle cx="28" cy="29.5" r="3" fill="${A}" stroke="${A}"/><circle cx="40" cy="26.5" r="3" fill="${A}" stroke="${A}"/>`,
   ogg:`<circle cx="35" cy="24" r="10.5" stroke="${A}"/><circle cx="35" cy="24" r="5"/><circle cx="35" cy="24" r="1.6" fill="${A}" stroke="none"/>`,
   sign:`<path d="M23 15h24M23 21h12"/><path d="M23 33c2-6 4-9 6-9s-1 8 1.5 8 2-5 4-5 1.5 3 3.5 3 2-2.5 3-3.5" stroke="${A}"/><path d="M23 36.2h24" stroke-width="1.8" opacity=".6"/>`,
   merge:`<path d="M23 16h5c4 0 7 2 7 7M23 32h5c4 0 7-2 7-7"/><path d="M35 23h10M41.5 19.5L45 23l-3.5 3.5" stroke="${A}"/>`,
   compress:`<path d="M28 15h16M28 21h16M28 27h10"/>`,
   split:`<path d="M22 15h7M22 21h7M22 27h7M42 21h9M42 27h9M42 33h6"/>`,
  };
  return `<g fill="none" stroke="${L}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round">${G[id]||''}</g>`;
}

function badge(text,p){
  const n=text.length, w=Math.round(10+n*8.4);
  return `<rect x="4" y="39" width="${w}" height="17" rx="4.2" fill="${p.bFill}"${p.bStroke?` stroke="${p.bStroke}" stroke-width="2"`:''}/>`+
  `<text class="bt" x="${4+w/2}" y="47.8" text-anchor="middle" dominant-baseline="central" textLength="${w-11}" lengthAdjust="spacingAndGlyphs" font-size="11.5" font-weight="800" fill="${p.bText}">${text}</text>`;
}

function makeIcon(id,o){
  const d=D[id], p=palette(id,o);
  const sw=3;
  const pageEl=(P,opaque)=>(opaque?`<path d="${P.d}" fill="${p.bg}"/>`:'')+
    `<path d="${P.d}" fill="${p.pageFill}" fill-opacity="${p.pageOp}" stroke="${p.pageStroke}" stroke-width="${sw}" stroke-linejoin="round"/>`+
    `<path d="${P.fold}" fill="none" stroke="${p.fold}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
  let out='';
  if(id==='unpack'){
    const pp=pg(18,46,4,34,9,4);
    out+=pageEl(pp,true)+glyphLines('M24 15h14M24 21h10',p.L);
    const folder='M8 22a4 4 0 0 1 4-4h11l5 5h24a4 4 0 0 1 4 4v28a4 4 0 0 1-4 4H12a4 4 0 0 1-4-4z';
    out+=`<path d="${folder}" fill="${p.bg}"/><path d="${folder}" fill="${p.pageFill}" fill-opacity="${p.pageOp}" stroke="${p.pageStroke}" stroke-width="${sw}" stroke-linejoin="round"/>`;
    out+=`<path d="M32 50V36M26 42l6-6 6 6" fill="none" stroke="${p.A}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
    return out;
  }
  if(id==='split'){
    const left='M31 4H20a4 4 0 0 0-4 4v48a4 4 0 0 0 4 4h11z';
    const right='M39 4H42L54 16V56a4 4 0 0 1-4 4H39z';
    const fold='M42 4v8a4 4 0 0 0 4 4h8';
    for(const dd of [left,right]) out+=`<path d="${dd}" fill="${p.bg}"/><path d="${dd}" fill="${p.pageFill}" fill-opacity="${p.pageOp}" stroke="${p.pageStroke}" stroke-width="${sw}" stroke-linejoin="round"/>`;
    out+=`<path d="${fold}" fill="none" stroke="${p.fold}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
    out+=`<path d="M35 1v62" stroke="${p.A}" stroke-width="2.4" stroke-linecap="round" stroke-dasharray="1 5.5" fill="none"/>`;
    out+=glyph('split',p.L,p.A)+badge(d.badge,p);
    return out;
  }
  if(id==='compress'){
    const P=pg(22,50,4,60,10,4);
    out+=pageEl(P)+glyph('compress',p.L,p.A);
    out+=`<path d="M8 17l6 6-6 6M62 17l-6 6 6 6" fill="none" stroke="${p.A==='#ffffff'||p.A==='#111111'?p.c:p.A}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
    return out+badge(d.badge,p);
  }
  if(id==='merge'){
    const P=pg(16,54,4,60,12,4);
    out+=`<path d="M26 1H56a4 4 0 0 1 4 4V52a4 4 0 0 1-4 4h-2" fill="none" stroke="${p.pageStroke==='none'?p.c:p.pageStroke}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round" opacity=".6"/>`;
    out+=pageEl(P,true)+glyph('merge',p.L,p.A);
    return out+badge(d.badge,p);
  }
  const P=pg(16,54,4,60,12,4);
  out+=pageEl(P)+glyph(id,p.L,p.A);
  if(d.badge) out+=badge(d.badge,p);
  return out;
}
function glyphLines(path,L){return `<path d="${path}" fill="none" stroke="${L}" stroke-width="2.6" stroke-linecap="round"/>`;}
function iconSVG(id,px,o,extra){return `<svg ${extra||''} width="${px}" height="${px}" viewBox="0 0 64 64" style="overflow:visible">${makeIcon(id,o)}</svg>`;}

if(typeof module!=='undefined') module.exports={FAM,D,GROUPS,TOOLS,makeIcon,palette,iconSVG,contrast,glyph,pg};
