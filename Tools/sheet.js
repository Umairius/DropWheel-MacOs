const L=require('./icons.js');
function sheet(o,theme){
  const bg=theme==='dark'?'#1c1c20':'#ffffff';
  const all=L.GROUPS.flatMap(g=>g[1]);
  const cols=9, cell=110;
  let s=`<svg xmlns="http://www.w3.org/2000/svg" width="${cols*cell}" height="${Math.ceil(all.length/cols)*cell}"><rect width="100%" height="100%" fill="${bg}"/>`;
  all.forEach((id,i)=>{const x=(i%cols)*cell+15,y=Math.floor(i/cols)*cell+8;
    s+=`<g transform="translate(${x} ${y})"><svg width="80" height="80" viewBox="0 0 64 64" overflow="visible">${L.makeIcon(id,{...o,theme})}</svg><text x="40" y="96" font-size="11" fill="${theme==='dark'?'#aaa':'#555'}" text-anchor="middle" font-family="sans-serif">${id}</text></g>`;});
  return s+'</svg>';
}
const fs=require('fs');
fs.writeFileSync('s_outline.svg',sheet({style:'outline',cmode:'family',accent:'#6EA8FF'},'dark'));
fs.writeFileSync('s_solid.svg',sheet({style:'solid',cmode:'family',accent:'#6EA8FF'},'dark'));
fs.writeFileSync('s_soft_light.svg',sheet({style:'soft',cmode:'family',accent:'#6EA8FF'},'light'));
