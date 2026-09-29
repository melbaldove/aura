(() => {
  const laptops = [
    {id:'kestrel',name:'Kestrel 14',price:1299,size:14,ram:32,battery:13,warranty:3,stock:true},
    {id:'swift',name:'Swift 14',price:1099,size:14,ram:16,battery:15,warranty:3,stock:true},
    {id:'orion',name:'Orion 14',price:1199,size:14,ram:32,battery:14,warranty:3,stock:true},
    {id:'lumen',name:'Lumen 14',price:1099,size:14,ram:32,battery:10,warranty:3,stock:true},
    {id:'atlas',name:'Atlas 15',price:1149,size:15,ram:32,battery:14,warranty:3,stock:true},
    {id:'nova',name:'Nova 14',price:999,size:14,ram:32,battery:14,warranty:1,stock:true},
    {id:'cove',name:'Cove 14',price:1099,size:14,ram:32,battery:14,warranty:3,stock:false}
  ];
  const docks = [
    {id:'beam',name:'Beam Dock',price:99,connector:'USB-C',monitors:2,resolution:'4K',power:65},
    {id:'anchor',name:'Anchor Dock',price:89,connector:'USB-A',monitors:2,resolution:'4K',power:0},
    {id:'pier',name:'Pier Dock',price:169,connector:'USB-C',monitors:2,resolution:'4K',power:90},
    {id:'harbor',name:'Harbor Dock',price:149,connector:'USB-C',monitors:2,resolution:'4K',power:100}
  ];
  const s = {view:'home',filters:{stock:false,size:false},laptop:null,dock:null,laptopQty:1,dockQty:1,office:null,shipping:null,budget:null,saved:false,audit:[]};
  let selected = null;
  const money = n => '$'+n.toLocaleString('en-US');
  const laptop = () => laptops.find(p=>p.id===s.laptop);
  const dock = () => docks.find(p=>p.id===s.dock);
  const total = () => (laptop()?.price||0)*s.laptopQty+(dock()?.price||0)*s.dockQty+(s.shipping==='express'?45:0);
  const button = (label,action,pressed,disabled=false) => `<button data-action="${action}" ${pressed===undefined?'':`aria-pressed="${pressed}"`} ${disabled?'disabled':''}>${label}</button>`;
  const nav = () => `<nav>${button('Laptops','view:laptops')}${button('Docks','view:docks')}${button('Request cart','view:cart')}</nav>`;
  const summary = () => `<p>Request: ${laptop()?`${s.laptopQty} × ${laptop().name}`:'No laptop'}; ${dock()?`${s.dockQty} × ${dock().name}`:'No dock'}. Total ${money(total())}.</p>`;
  const filtered = () => laptops.filter(p=>(!s.filters.stock||p.stock)&&(!s.filters.size||p.size===14));
  const filters = () => `<div>${button('Only in-stock laptops','stock',s.filters.stock)}${button('Only 14-inch laptops','size',s.filters.size)}<span> Filters: stock ${s.filters.stock?'on':'off'}, 14-inch ${s.filters.size?'on':'off'}</span></div>`;
  const detail = p => `<h2>${p.name}</h2><p>${money(p.price)}${p.ram?` · ${p.size}-inch · ${p.ram} GB RAM · ${p.battery} hours battery · ${p.warranty} years warranty · ${p.stock?'In stock':'Out of stock'}`:` · ${p.connector} · ${p.monitors} monitors at ${p.resolution} · ${p.power} W charging`}</p>${button(p.ram?'Add laptop':'Add dock',p.ram?'add:laptop':'add:dock',undefined,p.stock===false)}`;
  const render = () => {
    document.title = 'Equipment request test';
    let body = '';
    switch(s.view) {
      case 'home': body='<h2>Equipment catalog</h2><p>Compare equipment and save a draft request. This is a local simulation.</p>'; break;
      case 'laptops': body=`<h2>Laptop catalog</h2>${filters()}${button('Compare laptops','view:laptop-compare')}<ul>${filtered().map(p=>`<li>${p.name} · ${money(p.price)} · ${p.stock?'In stock':'Out of stock'}</li>`).join('')}</ul>`; break;
      case 'laptop-compare': body=`<h2>Laptop comparison</h2>${filters()}<table><thead><tr><th>Model</th><th>Price</th><th>Screen</th><th>RAM</th><th>Battery</th><th>Warranty</th><th>Choose</th></tr></thead><tbody>${filtered().map(p=>`<tr><td>${p.name}</td><td>${money(p.price)}</td><td>${p.size} inches</td><td>${p.ram} GB</td><td>${p.battery} hours</td><td>${p.warranty} years</td><td>${button('Choose '+p.name,'laptop:'+p.id,undefined,!p.stock)}</td></tr>`).join('')}</tbody></table>`; break;
      case 'laptop-detail': body=detail(selected); break;
      case 'docks': body=`<h2>Dock catalog</h2>${button('Compare docks','view:dock-compare')}<ul>${docks.map(p=>`<li>${p.name} · ${money(p.price)}</li>`).join('')}</ul>`; break;
      case 'dock-compare': body=`<h2>Dock comparison</h2><table><thead><tr><th>Model</th><th>Price</th><th>Connection</th><th>Monitors</th><th>Charging</th><th>Choose</th></tr></thead><tbody>${docks.map(p=>`<tr><td>${p.name}</td><td>${money(p.price)}</td><td>${p.connector}</td><td>${p.monitors} × ${p.resolution}</td><td>${p.power} W</td><td>${button('Choose '+p.name,'dock:'+p.id)}</td></tr>`).join('')}</tbody></table>`; break;
      case 'dock-detail': body=detail(selected); break;
      case 'cart': body=`<h2>Request cart</h2>${laptop()?`<article>${laptop().name} · quantity ${s.laptopQty} ${button('Decrease '+laptop().name+' quantity','minus:laptop',undefined,s.laptopQty<=1)}${button('Increase '+laptop().name+' quantity','plus:laptop')}</article>`:''}${dock()?`<article>${dock().name} · quantity ${s.dockQty} ${button('Decrease '+dock().name+' quantity','minus:dock',undefined,s.dockQty<=1)}${button('Increase '+dock().name+' quantity','plus:dock')}</article>`:''}${button('Configure request','view:configure',undefined,!s.laptop||!s.dock)}`; break;
      case 'configure': body=`<h2>Delivery and budget</h2><section><h3>Office</h3>${['Manila','Cebu','Singapore'].map(x=>button(x+' office','office:'+x,s.office===x)).join('')}</section><section><h3>Shipping</h3>${button('Standard shipping','shipping:standard',s.shipping==='standard')}${button('Express shipping (+$45)','shipping:express',s.shipping==='express')}</section><section><h3>Budget</h3>${['Engineering','Operations','Design'].map(x=>button(x,'budget:'+x,s.budget===x)).join('')}</section>${button('Review request','view:review',undefined,!s.office||!s.shipping||!s.budget)}`; break;
      case 'review': body=`<h2>Review request</h2>${detail(laptop()).split('<button')[0]}${detail(dock()).split('<button')[0]}<p>Office: ${s.office}. Shipping: ${s.shipping}. Budget: ${s.budget}.</p>${button('Edit request','view:cart')}${button('Save draft','save')}`; break;
      case 'saved': body=`<h2>Draft saved</h2><p>Status: draft. Office: ${s.office}. Shipping: ${s.shipping}. Budget: ${s.budget}.</p><p>Laptop filters: in stock ${s.filters.stock?'on':'off'}; 14-inch ${s.filters.size?'on':'off'}.</p><p>${laptop().name}: ${laptop().ram} GB RAM, ${laptop().battery} hours battery, ${laptop().warranty} years warranty.</p><p>${dock().name}: ${dock().connector}, ${dock().monitors} × ${dock().resolution}, ${dock().power} W charging.</p>`; break;
    }
    document.body.innerHTML=`<main><header><h1>Equipment requests</h1>${nav()}${summary()}</header>${body}</main>`;
    history.replaceState(null,'','#'+s.view);
    scrollTo(0,0);
    document.querySelectorAll('button[data-action]').forEach(b=>b.onclick=()=>act(b.dataset.action,b.textContent));
  };
  function act(action,label) {
    s.audit.push(label);
    const [kind,value]=action.split(':');
    if(kind==='view') s.view=value;
    if(kind==='stock') s.filters.stock=!s.filters.stock;
    if(kind==='size') s.filters.size=!s.filters.size;
    if(kind==='laptop'){selected=laptops.find(p=>p.id===value);s.view='laptop-detail';}
    if(kind==='dock'){selected=docks.find(p=>p.id===value);s.view='dock-detail';}
    if(kind==='add'){s[value]=selected.id;s.view='cart';}
    if(kind==='plus') s[value+'Qty']++;
    if(kind==='minus') s[value+'Qty']--;
    if(kind==='office'||kind==='shipping'||kind==='budget')s[kind]=value;
    if(kind==='save'){s.saved=true;s.view='saved';localStorage.setItem('procurement_draft',JSON.stringify(s));}
    render();
  }
  const style=document.createElement('style');
  style.textContent='html,body{margin:0!important;padding:0!important;background:#fff!important;color:#111!important;font:14px Arial!important}main{max-width:1040px;margin:12px}h1{font-size:20px;margin:6px 0}h2{font-size:18px;margin:10px 0}h3{font-size:14px;margin:8px 0}p{margin:8px 0}button{margin:3px;padding:5px 8px;font:13px Arial}button[aria-pressed=true]{background:#cdebd8;border:2px solid #236837}table{border-collapse:collapse;margin-top:8px}td,th{padding:4px 7px;border:1px solid #bbb;text-align:left}li{margin:6px 0}article{margin:8px 0}';
  document.head.appendChild(style);
  window.getProcurementState=()=>JSON.parse(JSON.stringify({...s,total:total()}));
  render();
  return true;
})()
