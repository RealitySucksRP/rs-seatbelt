'use strict';
// Seatbelt gizmo adapted from the owner's RS Consumables Alignment Studio.
// Third-party Three.js modules are bundled locally under ./vendor; no CDN/runtime dependency.
import * as THREE from './vendor/three.module.js';
import { TransformControls } from './vendor/TransformControls.js';

const panel = document.querySelector('#alignment-editor');
const group = document.querySelector('#alignment-controls');
const status = document.querySelector('#align-status');
const saveButton = document.querySelector('#align-save');
const layer = document.querySelector('#gizmo-layer');
const axes = [
  {key:'x', label:'X · Side', min:-.35,max:.35,step:.001,unit:'m'},
  {key:'y', label:'Y · Depth',min:-.35,max:.35,step:.001,unit:'m'},
  {key:'z', label:'Z · Height',min:-.35,max:.35,step:.001,unit:'m'},
  {key:'rx',label:'Pitch',min:-180,max:180,step:.5,unit:'°'},
  {key:'ry',label:'Roll',min:-180,max:180,step:.5,unit:'°'},
  {key:'rz',label:'Yaw',min:-180,max:180,step:.5,unit:'°'}
];
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(36, window.innerWidth/window.innerHeight, .01, 5000);
const boneAnchor = new THREE.Group();
const beltProxy = new THREE.Object3D();
boneAnchor.add(beltProxy);
scene.add(boneAnchor);
const ORDER_MAP = {0:'YZX',1:'ZYX',2:'YXZ',3:'XYZ',4:'ZXY',5:'XZY'};
let renderer, transform;
let active=false, busy=false, dragging=false, rightDrag=false, dragMode='', lastPointer={x:0,y:0};
let mode='translate', space='local', moveSnap=.001, rotationSnap=.5;
let defaults={}, saved={}, values={}, previewTimer=null;
let suppress=false;
let profile={}, savedProfile={}, serverProfile={}, owner=false, personalMode='server';
let viewGeneration=0;
let libraries={personal:{props:[],animations:[]},server:{props:[],animations:[]}};
const libraryButtons=['save-prop','remove-prop','save-fasten','remove-fasten','save-removal','remove-removal'];
const field=id=>document.getElementById(id);
function collection(scope,kind){
  const items=libraries?.[scope]?.[kind];return Array.isArray(items)?items:[];
}
function renderLibraries(reset=false){
  for(const [id,kind] of [['saved-props','props'],['saved-fasten','animations'],['saved-removal','animations']]){
    const select=field(id),previous=select.value;
    select.replaceChildren(new Option(kind==='props'?'Saved props...':'Saved animations...',''));
    for(const scope of ['personal','server']){
      const items=collection(scope,kind);if(!items.length)continue;
      const group=document.createElement('optgroup');group.label=scope==='personal'?'My library':'Server library';
      items.forEach((item,index)=>{
        const label=kind==='props'?item:`${item.dict} : ${item.clip}`;
        const option=new Option(label,`${scope}:${index}`);option.title=label;group.append(option);
      });
      select.append(group);
    }
    if(!reset&&[...select.options].some(option=>option.value===previous))select.value=previous;
  }
}
function selectedAsset(id,kind){
  const [scope,index]=field(id).value.split(':');
  const item=collection(scope,kind)[Number(index)];
  return item?{scope,item}:null;
}
function readAnimation(which){
  const parts=field(`profile-${which}`).value.trim().split(':').map(value=>value.trim());
  if(parts.length!==2||!parts[0]||!parts[1])throw new Error('Use dictionary : clip for each animation.');
  for(const id of [`${which}-duration`,`${which}-speed`]){
    if(!field(id).checkValidity()||field(id).value==='')throw new Error('Check animation duration and speed.');
  }
  return {dict:parts[0],clip:parts[1],durationMs:Number(field(`${which}-duration`).value),
    speed:Number(field(`${which}-speed`).value),enabled:field(`${which}-enabled`).checked};
}
async function editLibrary(which,remove){
  if(!active||busy)return;
  const generation=viewGeneration;
  try{
    const kind=which==='prop'?'props':'animations';
    const id=which==='prop'?'saved-props':`saved-${which}`;
    const selected=remove?selectedAsset(id,kind):null;
    if(remove&&!selected)throw new Error('Select a saved entry to remove.');
    const item=remove?selected.item:which==='prop'?field('profile-model').value.trim():readAnimation(which);
    const scope=remove?selected.scope:owner?field('library-scope').value:'personal';
    busyState(true);
    const reply=await post('strapLibrary',{kind,scope,item,action:remove?'remove':'save'});
    if(generation!==viewGeneration)return;
    if(!reply?.ok)throw new Error(reply?.message||'Library request failed.');
    libraries=reply.libraries||libraries;renderLibraries();
    status.textContent=remove?'Removed from library. Calibration unchanged.':'Saved to library. Calibration unchanged.';
  }catch(error){if(generation===viewGeneration)status.textContent=error.message;}
  finally{if(generation===viewGeneration)busyState(false);}
}
for(const which of ['prop','fasten','removal']){
  field(`save-${which}`).addEventListener('click',()=>editLibrary(which,false));
  field(`remove-${which}`).addEventListener('click',()=>editLibrary(which,true));
  const id=which==='prop'?'saved-props':`saved-${which}`;
  field(id).addEventListener('change',()=>{
    if(!active||busy)return;
    const selected=selectedAsset(id,which==='prop'?'props':'animations');if(!selected)return;
    if(which==='prop')field('profile-model').value=selected.item;
    else{
      const a=selected.item;field(`profile-${which}`).value=`${a.dict} : ${a.clip}`;
      field(`${which}-duration`).value=a.durationMs;field(`${which}-speed`).value=a.speed;
      field(`${which}-enabled`).checked=a.enabled!==false;
    }
    runPreview();
  });
}
function tab(name){
  field('assets-page').hidden=name!=='assets';field('fit-page').hidden=name!=='fit';
  for(const id of ['assets','fit']){
    field(`tab-${id}`).classList.toggle('align-primary',name===id);
    field(`tab-${id}`).setAttribute('aria-selected',String(name===id));
  }
  panel.scrollTop=0;
}
field('tab-assets').addEventListener('click',()=>tab('assets'));
field('tab-fit').addEventListener('click',()=>tab('fit'));
function fillProfile(p){
  profile=structuredClone(p); field('profile-model').value=p.model;
  field('profile-bone').value=p.bone;
  field('profile-fasten').value=`${p.animation.dict} : ${p.animation.clip}`;
  field('profile-removal').value=`${p.removalAnimation.dict} : ${p.removalAnimation.clip}`;
  field('fasten-enabled').checked=p.animation.enabled!==false;field('removal-enabled').checked=p.removalAnimation.enabled!==false;
  field('fasten-duration').value=p.animation.durationMs;field('fasten-speed').value=p.animation.speed;
  field('removal-duration').value=p.removalAnimation.durationMs;field('removal-speed').value=p.removalAnimation.speed;
}
function readProfile(){
  if(!field('asset-fields').disabled){
    for(const input of field('asset-fields').querySelectorAll('input')){
      if(!input.checkValidity())throw new Error('Check the prop, bone and timing values.');
    }
    profile={...profile,model:field('profile-model').value.trim(),bone:Number(field('profile-bone').value),
      animation:readAnimation('fasten'),removalAnimation:readAnimation('removal')};
  }
  return {...profile,...sanitize(values)};
}
async function previewProfile(){
  clearPreviewTimer();
  const generation=viewGeneration;
  const candidate=readProfile();
  // Flush a pending gizmo/numeric edit before replacing assets.
  const fit=await post('strapPreview',sanitize(values));
  if(!fit?.ok)throw new Error('Unable to apply calibration.');
  if(!active||generation!==viewGeneration)throw new Error('Preview cancelled.');
  const reply=await post('strapProfile',candidate);
  if(!reply?.ok)throw new Error(reply?.message||'Preview unavailable.');
}
function busyState(value){
  busy=value;
  for(const id of ['align-save','server-save','profile-preview','test-fasten','test-removal'])field(id).disabled=value;
  for(const id of libraryButtons)field(id).disabled=value;
}
async function runPreview(test){
  if(!active||busy)return;
  const generation=viewGeneration;
  busyState(true);
  try{
    await previewProfile();
    if(generation!==viewGeneration)return;
    if(test!==undefined){
      const reply=await post('strapTest',{removal:test});
      if(!reply?.ok)throw new Error(reply?.message||'Animation test cancelled.');
    }
    if(generation===viewGeneration)status.textContent='Local preview - unsaved';
  }catch(error){if(generation===viewGeneration)status.textContent=error.message;}finally{if(generation===viewGeneration)busyState(false);}
}
field('profile-preview').addEventListener('click',()=>runPreview());
field('test-fasten').addEventListener('click',()=>runPreview(false));
field('test-removal').addEventListener('click',()=>runPreview(true));
field('profile-default').addEventListener('click',()=>{
  if(!active||busy)return;
  fillProfile({...serverProfile,...sanitize(values),bone:Number(field('profile-bone').value)});
  runPreview();
});

function clamp(n,min,max){return Math.max(min,Math.min(max,n));}
function number(n, fallback=0){const v=Number(n);return Number.isFinite(v)?v:fallback;}
function gamePos(p){return new THREE.Vector3(number(p.x),number(p.z),-number(p.y));}
function setGameRotation(object,r){
  object.rotation.order=ORDER_MAP[2];
  object.rotation.set(THREE.MathUtils.degToRad(number(r.x)),THREE.MathUtils.degToRad(number(r.z)),THREE.MathUtils.degToRad(-number(r.y)));
}
function boundedDegrees(r){let n=((r+180)%360+360)%360-180;return clamp(n,-180,180);}
function readTransform(){
  return {
    x:beltProxy.position.x, y:-beltProxy.position.z, z:beltProxy.position.y,
    rx:boundedDegrees(THREE.MathUtils.radToDeg(beltProxy.rotation.x)),
    ry:boundedDegrees(-THREE.MathUtils.radToDeg(beltProxy.rotation.z)),
    rz:boundedDegrees(THREE.MathUtils.radToDeg(beltProxy.rotation.y))
  };
}
function sanitize(incoming){
  const out={};
  for(const a of axes){
    const n=Number(incoming?.[a.key]);
    if(!Number.isFinite(n)) return null;
    out[a.key]=clamp(n,a.min,a.max);
  }
  return out;
}
function applyTransform(data,send=false){
  const v=sanitize(data);
  if(!v)return;
  suppress=true;
  values=v;
  beltProxy.position.set(v.x,v.z,-v.y);
  setGameRotation(beltProxy,{x:v.rx,y:v.ry,z:v.rz});
  beltProxy.updateMatrixWorld(true);
  refreshFields();
  suppress=false;
  if(send) preview();
}
function refreshFields(){
  for(const a of axes){
    const slider=group.querySelector(`[data-slide="${a.key}"]`);
    const numeric=group.querySelector(`[data-numeric="${a.key}"]`);
    if(slider) slider.value=String(number(values[a.key]));
    if(numeric && numeric!==document.activeElement) numeric.value=number(values[a.key]).toFixed(a.key.length===1?3:1);
  }
}
function cameraPost(payload){
  if(!active)return;
  post('strapCamera',payload).catch(()=>{status.textContent='Camera request failed — check F8';});
}
async function post(name,payload={}){
  const controller=new AbortController();
  const timeout=setTimeout(()=>controller.abort(),12000);
  try{
  const response=await fetch(`https://${GetParentResourceName()}/${name}`,{
    method:'POST',headers:{'Content-Type':'application/json;charset=UTF-8'},body:JSON.stringify(payload),signal:controller.signal
  });
  return response.json();
  }finally{clearTimeout(timeout);}
}
function preview(){
  if(!active||busy||suppress)return;
  if(previewTimer!==null)clearTimeout(previewTimer);
  previewTimer=setTimeout(()=>{
    previewTimer=null;
    if(!active||busy)return;
    post('strapPreview',sanitize(values)).catch(()=>{status.textContent='Preview failed — check F8';});
  },35);
}
function clearPreviewTimer(){if(previewTimer!==null)clearTimeout(previewTimer);previewTimer=null;}
function setMode(next){
  mode=next==='rotate'?'rotate':'translate';
  transform?.setMode(mode);
  document.querySelector('#gizmo-move').classList.toggle('align-primary',mode==='translate');
  document.querySelector('#gizmo-rotate').classList.toggle('align-primary',mode==='rotate');
}
function setSpace(){space=space==='local'?'world':'local';transform?.setSpace(space);
  document.querySelector('#gizmo-space').textContent=`${space==='local'?'Local':'World'} · Q`;
}
function setPrecision(fine){
  moveSnap=fine?.001:.01;rotationSnap=fine?.5:5;
  transform?.setTranslationSnap(moveSnap);
  transform?.setRotationSnap(THREE.MathUtils.degToRad(rotationSnap));
  document.querySelector('#gizmo-fine').classList.toggle('align-primary',fine);
  document.querySelector('#gizmo-normal').classList.toggle('align-primary',!fine);
}
function resize(){
  if(!renderer)return;
  renderer.setSize(window.innerWidth,window.innerHeight);
  camera.aspect=window.innerWidth/window.innerHeight;
  camera.updateProjectionMatrix();
}
function ensureRenderer(){
  if(renderer)return true;
  try{
    renderer=new THREE.WebGLRenderer({alpha:true,antialias:true});
    renderer.setPixelRatio(Math.min(window.devicePixelRatio||1,1.5));
    renderer.setSize(window.innerWidth,window.innerHeight);
    renderer.setClearColor(0,0);
    renderer.domElement.id='seatbelt-gizmo-canvas';
    layer.appendChild(renderer.domElement);
    transform=new TransformControls(camera,renderer.domElement);
    transform.attach(beltProxy);
    transform.size=.64;
    scene.add(transform.getHelper());
    transform.addEventListener('objectChange',()=>{
      if(!active||suppress)return;
      const v=readTransform();
      applyTransform(v,false); // enforce server-safe limits when dragging
      status.textContent='3D preview · Unsaved';
      preview();
    });
    transform.addEventListener('mouseDown',()=>{dragging=true;});
    transform.addEventListener('mouseUp',()=>{dragging=false;});
    transform.addEventListener('dragging-changed',e=>{dragging=e.value;});
    const canvas=renderer.domElement;
    canvas.addEventListener('contextmenu',e=>e.preventDefault());
    canvas.addEventListener('pointerdown',e=>{
      if(!active||dragging)return;
      if(e.button===2)dragMode='orbit';
      else if(e.button===1){e.preventDefault();dragMode='pan';}
      else return;
      rightDrag=true;
      lastPointer={x:e.clientX,y:e.clientY};
      canvas.setPointerCapture?.(e.pointerId);
    });
    canvas.addEventListener('pointermove',e=>{
      if(!active||!rightDrag)return;
      const dx=e.clientX-lastPointer.x,dy=e.clientY-lastPointer.y;
      lastPointer={x:e.clientX,y:e.clientY};
      if(dragMode==='pan')cameraPost({action:'pan',dy});
      else cameraPost({action:'orbit',dx,dy});
    });
    canvas.addEventListener('pointerup',e=>{if(e.button===1||e.button===2){rightDrag=false;dragMode='';}});
    canvas.addEventListener('pointercancel',()=>{rightDrag=false;dragMode='';dragging=false;});
    canvas.addEventListener('wheel',e=>{
      if(!active)return;
      e.preventDefault();cameraPost({action:'zoom',delta:e.deltaY});
    },{passive:false});
    // Render only while the admin opens the alignment panel. Normal gameplay
    // keeps the entire Three.js/WebGL layer asleep.
    window.addEventListener('resize',resize);
    setMode('translate');setPrecision(true);
    return true;
  }catch(err){
    console.warn('[rs-seatbelt] Three.js gizmo failed to initialize',err);
    status.textContent='3D gizmo unavailable; numeric alignment is still usable.';
    return false;
  }
}
function closeView(){
  viewGeneration++;
  active=false;busy=false;rightDrag=false;dragging=false;clearPreviewTimer();
  if(transform){transform.enabled=false;transform.visible=false;}
  if(renderer)renderer.setAnimationLoop(null);
  layer.hidden=true;panel.hidden=true;
  document.body.classList.remove('show-editor');
}
async function close(){
  if(!active)return;
  closeView();
  try{await post('strapClose');}catch(_){/* Client will clean up on vehicle exit/resource stop. */}
}
for(const a of axes){
  const row=document.createElement('div');row.className='align-axis-row';
  const label=document.createElement('label');label.textContent=a.label;
  const slider=document.createElement('input');slider.type='range';slider.min=a.min;slider.max=a.max;slider.step=a.step;slider.dataset.slide=a.key;
  const numeric=document.createElement('input');numeric.type='number';numeric.min=a.min;numeric.max=a.max;numeric.step=a.step;numeric.dataset.numeric=a.key;numeric.className='align-numeric';
  row.append(label,slider,numeric);group.append(row);
  const change=value=>{
    if(!active||busy)return;
    const n=Number(value);if(!Number.isFinite(n))return;
    const next={...values,[a.key]:clamp(n,a.min,a.max)};
    applyTransform(next,true);
    status.textContent='Manual preview · Unsaved';
  };
  slider.addEventListener('input',e=>change(e.target.value));
  numeric.addEventListener('change',e=>change(e.target.value));
}
document.querySelector('#gizmo-move').addEventListener('click',()=>setMode('translate'));
document.querySelector('#gizmo-rotate').addEventListener('click',()=>setMode('rotate'));
document.querySelector('#gizmo-space').addEventListener('click',setSpace);
document.querySelector('#gizmo-fine').addEventListener('click',()=>setPrecision(true));
document.querySelector('#gizmo-normal').addEventListener('click',()=>setPrecision(false));
document.querySelectorAll('[data-camera]').forEach(button=>button.addEventListener('click',()=>{
  const preset=button.dataset.camera;
  const motions={
    'zoom-in':{action:'zoom',delta:-90},'zoom-out':{action:'zoom',delta:90},
    up:{action:'pan',dy:-35},down:{action:'pan',dy:35}
  };
  cameraPost(motions[preset]||{action:'preset',preset});
}));
document.querySelector('#align-reset').addEventListener('click',()=>{
  if(!active||busy)return;applyTransform(defaults,true);status.textContent='Calibration reset - unsaved';
});
document.querySelector('#align-revert').addEventListener('click',()=>{
  if(!active||busy)return;fillProfile(savedProfile);applyTransform(saved,false);runPreview();
});
document.querySelector('#align-close').addEventListener('click',close);
document.addEventListener('keydown',e=>{
  if(!active)return;
  if(e.key==='Escape'){e.preventDefault();close();return;}
  if(e.target instanceof HTMLInputElement)return;
  const key=e.key.toLowerCase();
  if(key==='w')setMode('translate');
  else if(key==='r')setMode('rotate');
  else if(key==='q')setSpace();
});
async function saveProfile(scope,reset=false){
  if(!active||busy)return;
  const generation=viewGeneration;
  busyState(true);clearPreviewTimer();
  status.textContent=scope==='server'?'Publishing server default...':'Saving personal preset...';
  try{
    if(!reset)await previewProfile();
    if(generation!==viewGeneration)return;
    const reply=await post('strapSave',{profile:readProfile(),scope,reset});
    if(generation!==viewGeneration)return;
    if(!reply?.ok)throw new Error(reply?.message||'Save request rejected');
    closeView();
  }catch(error){
    if(generation!==viewGeneration)return;
    status.textContent=error?.name==='AbortError'?'Request timed out. Reload the saved preset before retrying.':error?.message||'Unable to save preset';
  }finally{if(generation===viewGeneration)busyState(false);}
}
saveButton.addEventListener('click',()=>saveProfile('personal'));
field('server-save').addEventListener('click',()=>saveProfile('server'));
window.addEventListener('message',({data})=>{
  if(!data||typeof data!=='object')return;
  if(data.action==='openAlignmentEditor'){
    viewGeneration++;
    active=true;busy=false;saveButton.disabled=false;
    owner=data.admin===true;personalMode=data.mode||'server';
    savedProfile=structuredClone(data.profile);serverProfile=structuredClone(data.serverProfile);
    fillProfile(savedProfile);busyState(false);
    libraries=data.libraries||{personal:{props:[],animations:[]},server:{props:[],animations:[]}};
    renderLibraries(true);field('library-scope').value=personalMode==='server'?'server':'personal';
    field('library-scope').hidden=!owner;field('library-scope-label').hidden=!owner;
    tab('assets');
    field('asset-fields').disabled=!owner&&personalMode!=='full';
    saveButton.hidden=personalMode==='server';
    field('server-save').hidden=!owner;
    field('profile-mode').textContent=personalMode==='server'?'Server default':personalMode==='alignment'?'Personal fit / server assets':'Personal preset';
    defaults=sanitize(data.defaults)||{};
    saved=sanitize(data.values)||defaults;
    applyTransform(saved,false);
    panel.hidden=false;layer.hidden=false;
    document.body.classList.add('show-editor');
    const ok=ensureRenderer();
    if(transform){transform.enabled=true;transform.visible=true;transform.attach(beltProxy);}
    if(renderer)renderer.setAnimationLoop(()=>{if(active)renderer.render(scene,camera);});
    setMode('translate');setPrecision(true);
    if(ok)status.textContent='Local preview - unsaved';
  }else if(data.action==='libraryChanged'){
    libraries=data.libraries||libraries;renderLibraries();
  }else if(data.action==='strapGizmoFrame'){
    if(!active||!data.anchor||!data.camera)return;
    boneAnchor.position.copy(gamePos(data.anchor.position));
    setGameRotation(boneAnchor,data.anchor.rotation);
    boneAnchor.updateMatrixWorld(true);
    camera.position.copy(gamePos(data.camera.position));
    camera.lookAt(gamePos(data.camera.target));
    camera.fov=number(data.camera.fov,36);camera.updateProjectionMatrix();
  }else if(data.action==='closeAlignmentEditor'||data.action==='stopAll'){
    closeView();
  }else if(data.action==='alignmentSaveError'){
    busy=false;saveButton.disabled=false;
    status.textContent=data.message||'Save rejected';
  }
});
