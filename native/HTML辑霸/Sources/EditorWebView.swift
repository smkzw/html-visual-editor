import SwiftUI
import WebKit

/// Native WKWebView canvas for live HTML editing.
struct EditorWebView: NSViewRepresentable {
    @ObservedObject var store: EditorStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController = context.coordinator.controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false
        // Keep opaque white so failed/empty loads don't show the gray chrome underneath
        wv.setValue(true, forKey: "drawsBackground")
        wv.underPageBackgroundColor = .white
        context.coordinator.webView = wv
        store.webView = context.coordinator
        context.coordinator.injectBridgeScript()
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.store = store
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, EditorWebControlling {
        var store: EditorStore
        weak var webView: WKWebView?
        let controller = WKUserContentController()
        private var pendingLoad: (URL, String?)?

        init(store: EditorStore) {
            self.store = store
            super.init()
            controller.add(LeakyScriptHandler { [weak self] msg in
                self?.handle(msg)
            }, name: "jiba")
        }

        func injectBridgeScript() {
            let js = Self.bridgeJS
            let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            controller.addUserScript(script)
        }

        func load(url: URL, token: String?) {
            // Set session cookie so sub-resources (CSS/JS/images) authenticate too
            if let token, let host = url.host {
                let cookie = HTTPCookie(properties: [
                    .domain: host,
                    .path: "/",
                    .name: "project_token",
                    .value: token,
                    .secure: "FALSE",
                    .expires: Date().addingTimeInterval(86400)
                ])
                if let cookie, let store = webView?.configuration.websiteDataStore.httpCookieStore {
                    store.setCookie(cookie) { [weak self] in
                        var req = URLRequest(url: url)
                        req.setValue(token, forHTTPHeaderField: "X-Project-Token")
                        self?.webView?.load(req)
                    }
                    return
                }
            }
            var req = URLRequest(url: url)
            if let token { req.setValue(token, forHTTPHeaderField: "X-Project-Token") }
            webView?.load(req)
        }

        func loadBlank() {
            webView?.loadHTMLString("<html><body style='background:transparent'></body></html>", baseURL: nil)
        }

        func eval(_ js: String) {
            webView?.evaluateJavaScript(js) { _, err in
                if let err { NSLog("JS error: \(err)") }
            }
        }

        func requestSave() {
            eval("window.__jiba && window.__jiba.save()")
        }

        func requestPresent() {
            eval("window.__jiba && window.__jiba.present(true)")
        }

        func exitPresent() {
            eval("window.__jiba && window.__jiba.present(false)")
        }

        private func handle(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                break
            case "selection":
                let tag = body["tag"] as? String
                let label = body["label"] as? String
                let anim = body["anim"] as? String ?? ""
                var snap = StyleSnapshot()
                snap.hasSelection = tag != nil
                snap.fontSize = body["fontSize"] as? String ?? "16"
                snap.fontWeight = body["fontWeight"] as? String ?? "400"
                snap.color = body["color"] as? String ?? "#1f2937"
                snap.background = body["background"] as? String ?? "#ffffff"
                snap.textAlign = body["textAlign"] as? String ?? "left"
                snap.width = body["width"] as? String ?? "0"
                snap.height = body["height"] as? String ?? "0"
                snap.opacity = body["opacity"] as? String ?? "1"
                snap.borderRadius = body["borderRadius"] as? String ?? "0"
                Task { @MainActor in
                    store.onSelectionChanged(tag: tag, label: label, style: snap, anim: anim)
                }
            case "dirty":
                Task { @MainActor in store.onDirty() }
            case "ppt":
                let active = body["active"] as? Bool ?? false
                let idx = body["index"] as? Int ?? 0
                let cnt = body["count"] as? Int ?? 0
                Task { @MainActor in store.onPPT(active: active, index: idx, count: cnt) }
            case "toast":
                let msg = body["msg"] as? String ?? ""
                Task { @MainActor in store.showToast(msg) }
            case "saved":
                let ok = body["ok"] as? Bool ?? false
                let msg = body["msg"] as? String ?? ""
                Task { @MainActor in
                    store.dirty = !ok ? store.dirty : false
                    store.showToast(msg, icon: ok ? "✓" : "⚠")
                }
            case "muted":
                break
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let path = store.currentPage?.path {
                let esc = path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("window.__jibaPath='\(esc)'", completionHandler: nil)
            }
            if let token = store.liveToken {
                webView.evaluateJavaScript("window.__jibaToken='\(token)'", completionHandler: nil)
            }
            webView.evaluateJavaScript("!!window.__jiba") { ok, _ in
                if (ok as? Bool) != true {
                    webView.evaluateJavaScript(Self.bridgeJS, completionHandler: nil)
                }
            }
        }

        /// Bridge JS: keeps DOM editing in the page, exposes ops to Swift.
        static let bridgeJS = #"""
        (function(){
          if(window.__jiba) return;
          const post=(o)=>{ try{ window.webkit.messageHandlers.jiba.postMessage(o);}catch(e){} };
          const $=id=>document.getElementById(id);
          let selected=null, editing=false, undoStack=[], redoStack=[], savedSnap=null;
          const MAX=60;

          function esc(s){return String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
          function rgbToHex(c){ if(!c) return '#000000'; if(c[0]==='#') return c.length===4?'#'+c[1]+c[1]+c[2]+c[2]+c[3]+c[3]:c; const m=c.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/); return m?'#'+[m[1],m[2],m[3]].map(x=>(+x).toString(16).padStart(2,'0')).join(''):'#000000'; }

          function ensureAnimLib(){
            let st=document.getElementById('v4-anim-lib');
            if(st) return st;
            st=document.createElement('style'); st.id='v4-anim-lib';
            st.textContent=`@keyframes v4-fade-in{from{opacity:0}to{opacity:1}}
          @keyframes v4-slide-up{from{opacity:0;transform:translateY(48px)}to{opacity:1;transform:translateY(0)}}
          @keyframes v4-slide-down{from{opacity:0;transform:translateY(-48px)}to{opacity:1;transform:translateY(0)}}
          @keyframes v4-slide-left{from{opacity:0;transform:translateX(48px)}to{opacity:1;transform:translateX(0)}}
          @keyframes v4-slide-right{from{opacity:0;transform:translateX(-48px)}to{opacity:1;transform:translateX(0)}}
          @keyframes v4-zoom-in{from{opacity:0;transform:scale(.55)}to{opacity:1;transform:scale(1)}}
          @keyframes v4-bounce-in{0%{opacity:0;transform:scale(.3)}50%{opacity:1;transform:scale(1.08)}70%{transform:scale(.94)}100%{opacity:1;transform:scale(1)}}
          @keyframes v4-rotate-in{from{opacity:0;transform:rotate(-12deg) scale(.7)}to{opacity:1;transform:rotate(0) scale(1)}}
          @keyframes v4-flip-in{from{opacity:0;transform:perspective(600px) rotateY(70deg)}to{opacity:1;transform:perspective(600px) rotateY(0)}}
          @keyframes v4-fade-out{from{opacity:1}to{opacity:0}}
          @keyframes v4-pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.08)}}
          @keyframes v4-shake{0%,100%{transform:translateX(0)}20%{transform:translateX(-6px)}40%{transform:translateX(6px)}60%{transform:translateX(-4px)}80%{transform:translateX(4px)}}
          @keyframes v4-float{0%,100%{transform:translateY(0)}50%{transform:translateY(-10px)}}
          @keyframes v4-glow{0%,100%{box-shadow:0 0 0 0 rgba(255,153,0,0)}50%{box-shadow:0 0 18px 4px rgba(255,153,0,.55)}}
          @keyframes v4-spin{from{transform:rotate(0)}to{transform:rotate(360deg)}}`;
            document.head.appendChild(st);
            return st;
          }

          function injectStyles(){
            if(document.getElementById('jiba-styles')) return;
            const st=document.createElement('style'); st.id='jiba-styles';
            st.textContent=`
              .j-hover{outline:2px dashed rgba(255,153,0,.75)!important;outline-offset:1px!important;cursor:pointer!important}
              .j-selected{outline:2.5px solid #ff9900!important;outline-offset:1px!important}
              .j-handle{position:absolute;width:10px;height:10px;background:#fff;border:2px solid #ff9900;border-radius:3px;z-index:2147483000;box-shadow:0 1px 4px rgba(0,0,0,.35);pointer-events:auto}
              .j-handle.nw{top:-5px;left:-5px;cursor:nwse-resize}.j-handle.n{top:-5px;left:calc(50% - 5px);cursor:ns-resize}.j-handle.ne{top:-5px;right:-5px;cursor:nesw-resize}
              .j-handle.e{top:calc(50% - 5px);right:-5px;cursor:ew-resize}.j-handle.w{top:calc(50% - 5px);left:-5px;cursor:ew-resize}
              .j-handle.sw{bottom:-5px;left:-5px;cursor:nesw-resize}.j-handle.s{bottom:-5px;left:calc(50% - 5px);cursor:ns-resize}.j-handle.se{bottom:-5px;right:-5px;cursor:nwse-resize}
              [contenteditable="true"]{outline:2px solid #002060!important;cursor:text!important}
            `;
            document.head.appendChild(st);
          }

          function strip(root){
            root.querySelectorAll('#jiba-styles,.j-handle,.j-selected,.j-hover,#v4-anim-lib').forEach(x=>{ if(x.id!=='v4-anim-lib') x.remove(); });
            root.querySelectorAll('.j-selected,.j-hover').forEach(x=>x.classList.remove('j-selected','j-hover'));
            root.querySelectorAll('[contenteditable="true"]').forEach(x=>x.removeAttribute('contenteditable'));
            root.querySelectorAll('[data-v4-ppt]').forEach(s=>{
              const o=s.getAttribute('data-v4-orig-opacity'); const pe=s.getAttribute('data-v4-orig-pe');
              s.style.removeProperty('opacity'); s.style.removeProperty('pointer-events'); s.style.removeProperty('transition');
              if(o) s.style.opacity=o; if(pe) s.style.pointerEvents=pe;
              s.removeAttribute('data-v4-ppt'); s.removeAttribute('data-v4-orig-opacity'); s.removeAttribute('data-v4-orig-pe');
            });
            root.querySelectorAll('[class=""]').forEach(x=>x.removeAttribute('class'));
          }

          function snapshot(){
            if(!document.body) return null;
            const c=document.body.cloneNode(true); strip(c); return c.innerHTML;
          }

          function pushUndo(){ const s=snapshot(); if(s==null) return; undoStack.push(s); if(undoStack.length>MAX) undoStack.shift(); redoStack=[]; }
          function restore(html){ deselect(); document.body.innerHTML=html; injectStyles(); bind(); detectPPT(); }

          function undo(){ if(!undoStack.length){ post({type:'toast',msg:'没有可撤销的操作'}); return;} const cur=snapshot(); if(cur) redoStack.push(cur); restore(undoStack.pop()); post({type:'dirty'}); }
          function redo(){ if(!redoStack.length){ post({type:'toast',msg:'没有可重做的操作'}); return;} const cur=snapshot(); if(cur){ undoStack.push(cur); if(undoStack.length>MAX) undoStack.shift(); } restore(redoStack.pop()); post({type:'dirty'}); }

          function removeHandles(){ document.querySelectorAll('.j-handle').forEach(h=>h.remove()); }
          function placeHandles(el){
            removeHandles(); if(!el||el.nodeType!==1) return;
            const cs=getComputedStyle(el);
            if(cs.position==='static'){ el.style.position='relative'; el.setAttribute('data-j-was-static','1'); }
            ['nw','n','ne','e','se','s','sw','w'].forEach(dir=>{
              const h=document.createElement('div'); h.className='j-handle '+dir; h.setAttribute('data-v4','1');
              el.appendChild(h);
              h.addEventListener('mousedown', ev=>{ ev.preventDefault(); ev.stopPropagation(); startResize(el,dir,ev); }, true);
            });
          }

          function startResize(el,dir,ev){
            pushUndo();
            const r=el.getBoundingClientRect();
            const st={x:ev.clientX,y:ev.clientY,w:r.width,h:r.height};
            const mm=e=>{
              const dx=e.clientX-st.x, dy=e.clientY-st.y;
              let nw=st.w, nh=st.h;
              if(dir.includes('e')) nw=st.w+dx; if(dir.includes('w')) nw=st.w-dx;
              if(dir.includes('s')) nh=st.h+dy; if(dir.includes('n')) nh=st.h-dy;
              nw=Math.max(16,nw); nh=Math.max(16,nh);
              el.style.width=nw+'px'; el.style.height=nh+'px';
              emitSelection();
            };
            const mu=()=>{ document.removeEventListener('mousemove',mm,true); document.removeEventListener('mouseup',mu,true); placeHandles(el); post({type:'dirty'}); };
            document.addEventListener('mousemove',mm,true); document.addEventListener('mouseup',mu,true);
          }

          function emitSelection(){
            if(!selected){ post({type:'selection', tag:null}); return; }
            const cs=getComputedStyle(selected);
            post({
              type:'selection',
              tag:selected.tagName.toLowerCase(),
              label:(selected.id?'#'+selected.id:(selected.className&&typeof selected.className==='string'?selected.className.split(/\s+/).filter(Boolean)[0]||'':'')) || selected.tagName.toLowerCase(),
              fontSize:String(Math.round(parseFloat(cs.fontSize)||16)),
              fontWeight:String(parseInt(cs.fontWeight)||400),
              color:rgbToHex(cs.color),
              background:(cs.backgroundColor&&cs.backgroundColor!=='rgba(0, 0, 0, 0)')?rgbToHex(cs.backgroundColor):'transparent',
              textAlign:cs.textAlign==='start'?'left':(cs.textAlign==='end'?'right':cs.textAlign),
              width:String(Math.round(selected.offsetWidth)),
              height:String(Math.round(selected.offsetHeight)),
              opacity:String(Number.isFinite(parseFloat(cs.opacity))?parseFloat(cs.opacity):1),
              borderRadius:String(Math.round(parseFloat(cs.borderRadius)||0)),
              anim:selected.style.animationName||selected.getAttribute('data-v4-anim')||''
            });
          }

          function select(el){
            if(selected){ selected.classList.remove('j-selected'); removeHandles(); }
            selected=el; el.classList.add('j-selected'); placeHandles(el); emitSelection();
          }
          function deselect(){
            if(selected){ selected.classList.remove('j-selected'); }
            selected=null; removeHandles(); post({type:'selection',tag:null});
          }

          function startEdit(el){
            select(el); editing=true; pushUndo();
            el.setAttribute('contenteditable','true');
            el.focus();
            const rng=document.createRange(); rng.selectNodeContents(el);
            const sel=getSelection(); sel.removeAllRanges(); sel.addRange(rng);
            const finish=()=>{
              if(!editing) return; editing=false;
              el.removeAttribute('contenteditable');
              el.removeEventListener('blur',finish);
              post({type:'dirty'}); emitSelection();
            };
            el.addEventListener('blur',finish);
            el.addEventListener('input',()=>post({type:'dirty'}));
          }

          function bind(){
            injectStyles();
            if(document._jBound) return; document._jBound=true;
            let lastHover=null, drag=null;
            document.addEventListener('mouseover', e=>{
              if(editing) return; const el=e.target;
              if(!el||el.nodeType!==1||el.hasAttribute('data-v4')) return;
              if(el===lastHover) return;
              if(lastHover) lastHover.classList.remove('j-hover');
              if(!['HTML','BODY','HEAD'].includes(el.tagName)){ el.classList.add('j-hover'); lastHover=el; }
            }, true);
            document.addEventListener('mouseout', ()=>{ if(lastHover){ lastHover.classList.remove('j-hover'); lastHover=null; } }, true);
            document.addEventListener('click', e=>{
              if(editing) return;
              const el=e.target; if(!el||el.nodeType!==1||el.hasAttribute('data-v4')) return;
              if(el.classList.contains('j-handle')) return;
              e.preventDefault(); e.stopPropagation();
              select(el);
            }, true);
            document.addEventListener('dblclick', e=>{
              const el=e.target; if(!el||el.nodeType!==1) return;
              if(['HTML','BODY','HEAD','IMG','IFRAME','VIDEO'].includes(el.tagName)) return;
              e.preventDefault(); e.stopPropagation(); startEdit(el);
            }, true);
            document.addEventListener('mousedown', e=>{
              if(editing||e.button!==0) return;
              const el=e.target; if(!el||el.nodeType!==1||el.classList.contains('j-handle')) return;
              if(el===selected){
                const cs=getComputedStyle(el);
                drag={el, x:e.clientX, y:e.clientY, l:parseFloat(cs.left)||0, t:parseFloat(cs.top)||0, ml:parseFloat(cs.marginLeft)||0, mt:parseFloat(cs.marginTop)||0, pos:cs.position, moved:false};
              }
            }, true);
            document.addEventListener('mousemove', e=>{
              if(!drag) return;
              const dx=e.clientX-drag.x, dy=e.clientY-drag.y;
              if(Math.abs(dx)+Math.abs(dy)>3 && !drag.moved){ drag.moved=true; pushUndo(); e.preventDefault(); }
              if(!drag.moved) return; e.preventDefault();
              if(drag.pos==='absolute'||drag.pos==='fixed'){ drag.el.style.left=(drag.l+dx)+'px'; drag.el.style.top=(drag.t+dy)+'px'; }
              else { drag.el.style.marginLeft=(drag.ml+dx)+'px'; drag.el.style.marginTop=(drag.mt+dy)+'px'; }
            }, true);
            document.addEventListener('mouseup', ()=>{ if(drag&&drag.moved){ post({type:'dirty'}); if(selected) placeHandles(selected); } drag=null; }, true);
            document.addEventListener('keydown', e=>{
              if((e.metaKey||e.ctrlKey)&&e.key==='s'){ e.preventDefault(); window.__jiba.save(); }
              if((e.metaKey||e.ctrlKey)&&e.key==='z'&&!e.shiftKey){ e.preventDefault(); window.__jiba.undo(); }
              if((e.metaKey||e.ctrlKey)&&(e.key==='y'||(e.key==='z'&&e.shiftKey))){ e.preventDefault(); window.__jiba.redo(); }
              if(e.key==='Escape'){ deselect(); }
              if((e.key==='Delete'||e.key==='Backspace')&&selected&&!editing){ e.preventDefault(); window.__jiba.deleteSelected(); }
            }, true);
          }

          function detectPPT(){
            const cands=['.deck > section','.slide','[data-slide]','.slide-item','section.slide'];
            let found=[];
            for(const c of cands){
              const arr=Array.from(document.querySelectorAll(c));
              if(arr.length>=2){ found=arr; break; }
            }
            if(found.length>=2){
              found.forEach((s,i)=>{
                if(!s.hasAttribute('data-v4-ppt')){
                  s.setAttribute('data-v4-orig-opacity', s.style.opacity||'');
                  s.setAttribute('data-v4-orig-pe', s.style.pointerEvents||'');
                  s.style.setProperty('transition','opacity .3s ease','important');
                }
                s.setAttribute('data-v4-ppt','1');
                if(i!==0){ s.style.setProperty('opacity','0','important'); s.style.setProperty('pointer-events','none','important'); }
                else { s.style.setProperty('opacity','1','important'); s.style.setProperty('pointer-events','auto','important'); }
              });
              post({type:'ppt', active:true, index:0, count:found.length});
            } else {
              post({type:'ppt', active:false, index:0, count:0});
            }
          }

          function pptSlides(){ return Array.from(document.querySelectorAll('[data-v4-ppt]')); }
          function pptNav(d){
            const slides=pptSlides(); if(!slides.length) return;
            let cur=slides.findIndex(s=>s.style.opacity==='1');
            if(cur<0) cur=0;
            const n=cur+d; if(n<0||n>=slides.length) return;
            slides.forEach((s,i)=>{
              if(i!==n){ s.style.setProperty('opacity','0','important'); s.style.setProperty('pointer-events','none','important'); }
              else { s.style.setProperty('opacity','1','important'); s.style.setProperty('pointer-events','auto','important'); }
            });
            post({type:'ppt', active:true, index:n, count:slides.length});
          }

          function serializeFull(){
            const clone=document.documentElement.cloneNode(true);
            strip(clone);
            // keep anim lib if present
            return '<!DOCTYPE html>\\n'+clone.outerHTML;
          }

          window.__jiba={
            ready:true,
            applyStyle(map){
              if(!selected) return;
              pushUndo();
              for(const [k,v] of Object.entries(map)){
                if(v==null) continue;
                if(k==='text') selected.textContent=v;
                else if(k==='html') selected.innerHTML=v;
                else selected.style[k]=v;
              }
              post({type:'dirty'}); emitSelection();
            },
            applyAnim(name,dur,delay,ease,iter){
              if(!selected) return; pushUndo(); ensureAnimLib();
              selected.style.setProperty('animation-name', name);
              selected.style.setProperty('animation-duration', dur+'s');
              selected.style.setProperty('animation-delay', delay+'s');
              selected.style.setProperty('animation-timing-function', ease||'ease');
              selected.style.setProperty('animation-iteration-count', iter===0?'infinite':String(iter||1));
              selected.style.setProperty('animation-fill-mode','both');
              selected.setAttribute('data-v4-anim', name);
              post({type:'dirty'}); emitSelection();
            },
            clearAnim(){
              if(!selected) return; pushUndo();
              ['animation-name','animation-duration','animation-delay','animation-timing-function','animation-iteration-count','animation-fill-mode','animation'].forEach(p=>selected.style.removeProperty(p));
              selected.removeAttribute('data-v4-anim');
              post({type:'dirty'}); emitSelection();
            },
            previewAnim(){
              if(!selected) return;
              selected.style.animation='none'; void selected.offsetWidth; selected.style.animation='';
            },
            align(mode){
              if(!selected||!selected.parentNode) return;
              pushUndo();
              const parent=selected.offsetParent||selected.parentElement;
              const pr=getComputedStyle(parent);
              if(pr.position==='static'){ parent.style.position='relative'; }
              selected.style.position='absolute';
              const pw=parent.clientWidth, ph=parent.clientHeight;
              const ew=selected.offsetWidth, eh=selected.offsetHeight;
              if(mode==='left'){ selected.style.left='0px'; selected.style.right='auto'; }
              if(mode==='right'){ selected.style.left='auto'; selected.style.right='0px'; }
              if(mode==='center'){ selected.style.left=Math.round((pw-ew)/2)+'px'; selected.style.right='auto'; }
              if(mode==='top'){ selected.style.top='0px'; selected.style.bottom='auto'; }
              if(mode==='bottom'){ selected.style.top='auto'; selected.style.bottom='0px'; }
              if(mode==='middle'){ selected.style.top=Math.round((ph-eh)/2)+'px'; selected.style.bottom='auto'; }
              post({type:'dirty'}); emitSelection();
            },
            deleteSelected(){
              if(!selected) return; pushUndo();
              if(selected.parentNode){ selected.remove(); deselect(); post({type:'dirty'}); }
            },
            duplicateSelected(){
              if(!selected) return; pushUndo();
              const c=selected.cloneNode(true);
              c.querySelectorAll('.j-handle').forEach(h=>h.remove());
              c.classList.remove('j-selected');
              selected.parentNode.insertBefore(c, selected.nextSibling);
              select(c); post({type:'dirty'});
            },
            insertShape(i){
              const shapes=[
                ['0 0 120 80','<rect x="4" y="4" width="112" height="72" rx="6"/>'],
                ['0 0 100 100','<circle cx="50" cy="50" r="46"/>'],
                ['0 0 140 80','<ellipse cx="70" cy="40" rx="66" ry="36"/>'],
                ['0 0 100 90','<polygon points="50,6 96,84 4,84"/>'],
                ['0 0 100 100','<polygon points="50,4 96,50 50,96 4,50"/>'],
                ['0 0 100 100','<polygon points="50,4 61,36 96,36 68,57 79,92 50,71 21,92 32,57 4,36 39,36"/>'],
                ['0 0 120 80','<polygon points="4,28 74,28 74,8 116,40 74,72 74,52 4,52"/>']
              ];
              const s=shapes[i]||shapes[0];
              pushUndo();
              const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
              svg.setAttribute('viewBox',s[0]); svg.setAttribute('width','200'); svg.setAttribute('height','140');
              svg.classList.add('j-shape'); svg.style.display='inline-block';
              const g=document.createElementNS('http://www.w3.org/2000/svg','g');
              g.setAttribute('fill','#ff9900'); g.innerHTML=s[1]; svg.appendChild(g);
              (document.body).appendChild(svg);
              select(svg); post({type:'dirty'});
            },
            insertNode(kind){
              pushUndo(); let el=null;
              if(kind==='textbox'){ el=document.createElement('div'); el.textContent='双击编辑文字'; el.style.cssText='padding:12px 16px;font-size:16px;min-width:120px'; }
              if(kind==='title'){ el=document.createElement('h2'); el.textContent='新标题'; el.style.cssText='font-size:28px;font-weight:800;margin:12px 0'; }
              if(kind==='button'){ el=document.createElement('a'); el.href='javascript:void(0)'; el.textContent='点击这里'; el.style.cssText='display:inline-block;padding:10px 22px;background:#002060;color:#fff;border-radius:8px;font-weight:600;text-decoration:none'; }
              if(kind==='divider'){ el=document.createElement('hr'); el.style.cssText='border:none;border-top:2px solid #e2e6ec;margin:20px 0'; }
              if(kind==='card'){ el=document.createElement('div'); el.innerHTML='<div style="font-weight:700;margin-bottom:6px">卡片标题</div><div style="color:#5f6b7a">描述文字</div>'; el.style.cssText='background:#fff;border:1px solid #e2e6ec;border-radius:12px;padding:16px;max-width:320px'; }
              if(kind==='icon'){ el=document.createElement('div'); el.textContent='⭐'; el.style.cssText='font-size:48px'; }
              if(el){ document.body.appendChild(el); select(el); post({type:'dirty'}); }
            },
            insertTable(rows,cols){
              pushUndo();
              const t=document.createElement('table'); t.style.borderCollapse='collapse';
              for(let r=0;r<rows;r++){ const tr=document.createElement('tr');
                for(let c=0;c<cols;c++){ const cell=document.createElement(r===0?'th':'td');
                  cell.textContent=r===0?('表头'+(c+1)):' '; cell.style.border='1px solid #94a3b8'; cell.style.padding='8px 12px';
                  if(r===0){ cell.style.background='#ff9900'; cell.style.color='#fff'; }
                  tr.appendChild(cell); }
                t.appendChild(tr); }
              document.body.appendChild(t); select(t); post({type:'dirty'});
            },
            insertImage(url){
              pushUndo();
              const img=document.createElement('img'); img.src=url; img.alt='图片'; img.style.maxWidth='240px';
              document.body.appendChild(img); select(img); post({type:'dirty'});
            },
            undo, redo, pptNav,
            pptDup(){ /* simplified */ },
            pptDel(){ /* simplified */ },
            setZoom(z){ document.documentElement.style.zoom=z; },
            setDevice(w,h){ /* frame size handled by Swift */ },
            export(){
              const html=serializeFull();
              const blob=new Blob([html],{type:'text/html;charset=utf-8'});
              const a=document.createElement('a'); a.href=URL.createObjectURL(blob);
              a.download=(document.title||'export')+'_导出.html';
              document.body.appendChild(a); a.click(); a.remove();
              post({type:'toast',msg:'已导出'});
            },
            copySelected(){ if(!selected) return; window.__jibaClip=selected.cloneNode(true); post({type:'toast',msg:'已复制'}); },
            cutSelected(){ if(!selected) return; pushUndo(); window.__jibaClip=selected.cloneNode(true); selected.remove(); deselect(); post({type:'dirty'}); },
            pasteSelected(){
              if(!window.__jibaClip){ post({type:'toast',msg:'剪贴板为空'}); return; }
              pushUndo();
              const c=window.__jibaClip.cloneNode(true);
              c.querySelectorAll('.j-handle').forEach(h=>h.remove());
              c.classList.remove('j-selected');
              (selected&&selected.parentNode?selected.parentNode:document.body).appendChild(c);
              select(c); post({type:'dirty'});
            },
            bringForward(){ if(!selected||!selected.nextElementSibling) return; pushUndo(); selected.parentNode.insertBefore(selected.nextElementSibling, selected); post({type:'dirty'}); },
            sendBackward(){ if(!selected||!selected.previousElementSibling) return; pushUndo(); selected.parentNode.insertBefore(selected, selected.previousElementSibling); post({type:'dirty'}); },
            bringToFront(){ if(!selected||!selected.parentNode) return; pushUndo(); selected.parentNode.appendChild(selected); post({type:'dirty'}); },
            sendToBack(){ if(!selected||!selected.parentNode) return; pushUndo(); selected.parentNode.insertBefore(selected, selected.parentNode.firstChild); post({type:'dirty'}); },
            toggleItalic(){
              if(!selected) return; pushUndo();
              const cs=getComputedStyle(selected);
              selected.style.fontStyle = cs.fontStyle==='italic' ? 'normal' : 'italic';
              post({type:'dirty'}); emitSelection();
            },
            toggleUnderline(){
              if(!selected) return; pushUndo();
              const cs=getComputedStyle(selected);
              selected.style.textDecoration = (cs.textDecorationLine||'').includes('underline') ? 'none' : 'underline';
              post({type:'dirty'}); emitSelection();
            },
            groupSelected(){
              if(!selected||!selected.parentNode) return; pushUndo();
              const g=document.createElement('div');
              g.style.cssText='display:inline-block;position:relative';
              selected.parentNode.insertBefore(g, selected);
              g.appendChild(selected);
              select(g); post({type:'dirty'});
            },
            selectAll(){ /* host-side conceptually; select body */ select(document.body); },
            present(on){
              document.documentElement.classList.toggle('j-presenting', !!on);
              if(on){ deselect(); document.querySelectorAll('.j-handle').forEach(h=>h.remove()); }
            },
            async save(){
              try{
                const content=serializeFull();
                const path=window.__jibaPath||'';
                if(!path){ post({type:'saved',ok:false,msg:'未指定保存路径'}); return; }
                // mtime via project read
                const tok=window.__jibaToken||'';
                const headers={'Content-Type':'application/json','X-Requested-With':'XMLHttpRequest'};
                if(tok) headers['X-Project-Token']=tok;
                const rr=await fetch('/api/project/read',{method:'POST',headers,body:JSON.stringify({path})});
                const rd=await rr.json();
                const res=await fetch('/api/project/save-raw',{method:'POST',headers,body:JSON.stringify({path,content,mtime:rd.mtime||0})});
                if(!res.ok){ const e=await res.json().catch(()=>({})); post({type:'saved',ok:false,msg:e.detail||('保存失败 '+res.status)}); return; }
                savedSnap=snapshot();
                post({type:'saved',ok:true,msg:'已保存'});
              }catch(e){ post({type:'saved',ok:false,msg:String(e)}); }
            }
          };

          // wait for DOM
          if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', ()=>{ bind(); detectPPT(); post({type:'ready'}); });
          else { bind(); detectPPT(); post({type:'ready'}); }
        })();
        """#
    }
}

/// Avoid retain cycle issues with WKScriptMessage handler
final class LeakyScriptHandler: NSObject, WKScriptMessageHandler {
    let cb: (WKScriptMessage) -> Void
    init(_ cb: @escaping (WKScriptMessage) -> Void) { self.cb = cb }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        cb(message)
    }
}

protocol EditorWebControlling: AnyObject {
    func load(url: URL, token: String?)
    func loadBlank()
    func eval(_ js: String)
    func requestSave()
    func requestPresent()
    func exitPresent()
}
