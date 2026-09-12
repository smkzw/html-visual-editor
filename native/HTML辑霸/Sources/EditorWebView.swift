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
        context.coordinator.dbg("makeNSView")
        context.coordinator.injectBridgeScript()
        // The store may have picked currentPage before this webview mounted
        // (phase switch happens one frame earlier) — replay the load now.
        if let page = store.currentPage {
            DispatchQueue.main.async { store.loadPage(page, force: true) }
        }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.store = store
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, EditorWebControlling {
        var store: EditorStore
        weak var webView: WKWebView?
        let controller = WKUserContentController()
        /// Page load requested before the WKWebView was mounted; replayed in makeNSView.
        var pendingLoad: (URL, String?)?

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
            // The store can request a load one frame before SwiftUI mounts the
            // webview (phase switch). Queue it and replay on attach.
            guard let webView else {
                pendingLoad = (url, token)
                dbg("load queued (webview not mounted)")
                return
            }
            dbg("load called \(url.absoluteString)")
            // Set session cookie so sub-resources (CSS/JS/images) authenticate too.
            // NOTE: do NOT wait for the setCookie completion — it can be dropped
            // (observed on macOS 26) and the main load never dispatches.
            var req = URLRequest(url: url)
            if let token {
                req.setValue(token, forHTTPHeaderField: "X-Project-Token")
                if let host = url.host,
                   let cookie = HTTPCookie(properties: [
                    .domain: host, .path: "/", .name: "project_token",
                    .value: token, .secure: "FALSE",
                    .expires: Date().addingTimeInterval(86400)
                   ]) {
                    webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
            }
            dbg("dispatching load")
            webView.load(req)
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
            // comma-expression: save() is async and returns a Promise the
            // evaluator can't serialize (noise error otherwise)
            eval("window.__jiba && (window.__jiba.save(), undefined)")
        }

        func requestPresent() {
            eval("window.__jiba && window.__jiba.present(true)")
        }

        func exitPresent() {
            eval("window.__jiba && window.__jiba.present(false)")
        }

        func dbg(_ s: String) {
            FileHandle.standardError.write(Data("[jiba] \(s)\n".utf8))
        }

        private func handle(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
                dbg("bad message: \(message.body)")
                return
            }
            switch type {
            case "ready":
                break
            case "selection":
                let tag = body["tag"] as? String
                let label = body["label"] as? String
                let anim = body["anim"] as? String ?? ""
                let trigger = body["animTrigger"] as? String ?? "load"
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
                    store.onSelectionChanged(tag: tag, label: label, style: snap, anim: anim, trigger: trigger)
                }
            case "dirty":
                Task { @MainActor in store.onDirty() }
            case "ppt":
                let active = body["active"] as? Bool ?? false
                let idx = body["index"] as? Int ?? 0
                let cnt = body["count"] as? Int ?? 0
                var slides: [SlideInfo] = []
                if let arr = body["slides"] as? [[String: Any]] {
                    for s in arr {
                        slides.append(SlideInfo(index: s["i"] as? Int ?? 0, label: s["label"] as? String ?? ""))
                    }
                } else {
                    dbg("slides cast failed: \(Swift.type(of: body["slides"] ?? "nil"))")
                }
                Task { @MainActor in store.onPPT(active: active, index: idx, count: cnt, slides: slides) }
            case "toast":
                let msg = body["msg"] as? String ?? ""
                Task { @MainActor in store.showToast(msg) }
            case "saved":
                let ok = body["ok"] as? Bool ?? false
                let msg = body["msg"] as? String ?? ""
                Task { @MainActor in
                    store.dirty = !ok ? store.dirty : false
                    store.showToast(msg, icon: ok ? "✓" : "⚠")
                    store.onSaved(ok: ok)
                }
            case "muted":
                break
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            dbg("didFail \(error.localizedDescription)")
            Task { @MainActor in store.showToast("页面加载失败: \(error.localizedDescription)", icon: "⚠") }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            dbg("didFailProvisional \(error.localizedDescription)")
            Task { @MainActor in store.showToast("页面打开失败: \(error.localizedDescription)", icon: "⚠") }
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            dbg("didCommit")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            dbg("didFinish")
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
          let selected=null, presentMode=false, editing=false, undoStack=[], redoStack=[], savedSnap=null, insertCount=0;
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

          // Persistent runtime for trigger-based animations (click/hover/scroll).
          // Injected into the saved file so triggers keep working outside the editor.
          function ensureAnimRuntime(){
            ensureAnimLib();
            if(document.getElementById('jiba-anim-runtime')) return;
            const s=document.createElement('script'); s.id='jiba-anim-runtime';
            s.textContent=`(function(){
              if(window.__jibaAnimRuntime) return; window.__jibaAnimRuntime=true;
              function cfg(el){ try{return JSON.parse(el.getAttribute('data-jiba-anim')||'null')}catch(e){return null} }
              function play(el){
                const c=cfg(el); if(!c) return;
                el.style.animation='none'; void el.offsetWidth;
                el.style.animationName=c.name;
                el.style.animationDuration=(c.dur||0.6)+'s';
                el.style.animationDelay=(c.delay||0)+'s';
                el.style.animationTimingFunction=c.ease||'ease';
                el.style.animationIterationCount=(c.iter===0?'infinite':String(c.iter||1));
                el.style.animationFillMode='both';
              }
              window.__jibaPlay=play;
              function arm(el){
                const c=cfg(el); if(!c||el.hasAttribute('data-jiba-armed')) return;
                el.setAttribute('data-jiba-armed','1');
                if(c.t==='click'){ el.addEventListener('click',()=>play(el)); el.style.cursor='pointer'; }
                else if(c.t==='hover'){ el.addEventListener('mouseenter',()=>play(el)); }
                else if(c.t==='scroll'){
                  if(!('IntersectionObserver' in window)){ play(el); return; }
                  const io=new IntersectionObserver(es=>{es.forEach(e=>{ if(e.isIntersecting){ play(el); io.unobserve(el);} })},{threshold:.35});
                  io.observe(el);
                }
              }
              window.__jibaAnimArm=arm;
              function armAll(){ document.querySelectorAll('[data-jiba-anim]').forEach(arm); }
              if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',armAll); else armAll();
            })();`;
            document.head.appendChild(s);
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
            // Remove ONLY nodes this editor injected. Editor marker CLASSES on user
            // elements must be un-classed, never removed — v4.2 deleted the element
            // under the mouse (.j-hover) from every save.
            root.querySelectorAll('#jiba-styles,.j-handle').forEach(x=>x.remove());
            root.querySelectorAll('.j-selected,.j-hover').forEach(x=>x.classList.remove('j-selected','j-hover'));
            root.querySelectorAll('[contenteditable="true"]').forEach(x=>x.removeAttribute('contenteditable'));
            root.querySelectorAll('[data-jiba-armed]').forEach(x=>x.removeAttribute('data-jiba-armed'));
            root.querySelectorAll('[data-j-was-static]').forEach(x=>{
              x.style.removeProperty('position');
              x.removeAttribute('data-j-was-static');
            });
            root.querySelectorAll('base[href^="/api/live/"]').forEach(x=>x.remove());
            root.querySelectorAll('[data-v4-ppt]').forEach(s=>{
              const o=s.getAttribute('data-v4-orig-opacity'); const pe=s.getAttribute('data-v4-orig-pe');
              s.style.removeProperty('opacity'); s.style.removeProperty('pointer-events'); s.style.removeProperty('transition');
              if(o) s.style.opacity=o; if(pe) s.style.pointerEvents=pe;
              s.removeAttribute('data-v4-ppt'); s.removeAttribute('data-v4-orig-opacity'); s.removeAttribute('data-v4-orig-pe');
            });
            root.querySelectorAll('[class=""]').forEach(x=>x.removeAttribute('class'));
            root.querySelectorAll('[style=""]').forEach(x=>x.removeAttribute('style'));
          }

          function snapshot(){
            if(!document.body) return null;
            const c=document.body.cloneNode(true); strip(c); return c.innerHTML;
          }

          function pushUndo(){ const s=snapshot(); if(s==null) return; undoStack.push(s); if(undoStack.length>MAX) undoStack.shift(); redoStack=[]; }
          function restore(html){ deselect(); document.body.innerHTML=html; injectStyles(); bind(); detectPPT(); }

          function undo(){ if(!undoStack.length){ post({type:'toast',msg:'没有可撤销的操作'}); return;} const cur=snapshot(); if(cur) redoStack.push(cur); restore(undoStack.pop()); post({type:'dirty'}); }
          function redo(){ if(!redoStack.length){ post({type:'toast',msg:'没有可重做的操作'}); return;} const cur=snapshot(); if(cur){ undoStack.push(cur); if(undoStack.length>MAX) undoStack.shift(); } restore(redoStack.pop()); post({type:'dirty'}); }

          function removeHandles(){
            document.querySelectorAll('.j-handle').forEach(h=>h.remove());
            // undo the position upgrade placeHandles made on static elements
            document.querySelectorAll('[data-j-was-static]').forEach(x=>{
              x.style.removeProperty('position');
              x.removeAttribute('data-j-was-static');
            });
          }
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

          function animOf(el){
            const cfg=(()=>{ try{return JSON.parse(el.getAttribute('data-jiba-anim')||'null')}catch(e){return null} })();
            return { name: el.getAttribute('data-v4-anim')||el.style.animationName||'',
                     trigger: cfg?cfg.t:(el.getAttribute('data-v4-trigger')||'load') };
          }

          function emitSelection(){
            if(!selected){ post({type:'selection', tag:null}); return; }
            const cs=getComputedStyle(selected);
            const a=animOf(selected);
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
              anim:a.name, animTrigger:a.trigger
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
              // in present mode let clicks pass through to trigger animations
              if(editing||presentMode) return;
              const el=e.target; if(!el||el.nodeType!==1||el.hasAttribute('data-v4')) return;
              if(el.classList.contains('j-handle')) return;
              e.preventDefault(); e.stopPropagation();
              select(el);
            }, true);
            document.addEventListener('dblclick', e=>{
              if(presentMode) return;
              const el=e.target; if(!el||el.nodeType!==1) return;
              if(['HTML','BODY','HEAD','IMG','IFRAME','VIDEO'].includes(el.tagName)) return;
              e.preventDefault(); e.stopPropagation(); startEdit(el);
            }, true);
            document.addEventListener('mousedown', e=>{
              if(editing||presentMode||e.button!==0) return;
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

          // MARK: PPT deck detection & navigation

          function deckCandidates(){
            const cands=['.deck > section','.slide','[data-slide]','.slide-item','section.slide'];
            for(const c of cands){
              const arr=Array.from(document.querySelectorAll(c));
              const ok=arr.filter(el=>{
                const st=getComputedStyle(el);
                const h=el.offsetHeight, w=el.offsetWidth;
                const positioned = st.position==='absolute'||st.position==='fixed';
                return positioned && h>=300 && w>=200;
              });
              if(ok.length>=2) return ok;
            }
            return [];
          }

          function slideLabel(s,i){
            const h=s.querySelector('h1,h2,h3,[data-slide-title]');
            const t=(h&&h.textContent?h.textContent:'').trim().replace(/\s+/g,' ').slice(0,24);
            return t||('第 '+(i+1)+' 页');
          }

          function detectPPT(){
            // Only treat as deck when slides are large fixed/absolute layers.
            // Aggressive `.slide` matching used to hide document sections → blank/black canvas.
            const found=deckCandidates();
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
              postPPT(0, found);
            } else {
              post({type:'ppt', active:false, index:0, count:0, slides:[]});
            }
          }

          function postPPT(idx, slides){
            post({type:'ppt', active:true, index:idx, count:slides.length,
                  slides:slides.map((s,i)=>({i, label:slideLabel(s,i)}))});
          }

          function pptSlides(){ return Array.from(document.querySelectorAll('[data-v4-ppt]')); }
          function pptCur(){
            const slides=pptSlides();
            let cur=slides.findIndex(s=>s.style.opacity==='1');
            if(cur<0) cur=0;
            return cur;
          }
          function pptGo(i){
            const slides=pptSlides(); if(!slides.length) return;
            const n=Math.max(0,Math.min(slides.length-1,i));
            slides.forEach((s,idx)=>{
              if(idx!==n){ s.style.setProperty('opacity','0','important'); s.style.setProperty('pointer-events','none','important'); }
              else { s.style.setProperty('opacity','1','important'); s.style.setProperty('pointer-events','auto','important'); }
            });
            postPPT(n, slides);
          }
          function pptNav(d){ pptGo(pptCur()+d); }

          function serializeFull(){
            const clone=document.documentElement.cloneNode(true);
            strip(clone);
            // keep anim lib + runtime if present (they carry user animations)
            return '<!DOCTYPE html>\n'+clone.outerHTML;
          }

          // MARK: insertion — new elements land in the CURRENT slide when a deck is open

          function insertTarget(){
            const slides=pptSlides();
            if(slides.length){ return slides[Math.min(pptCur(),slides.length-1)]; }
            return document.body;
          }
          function placeIn(el){
            const host=insertTarget();
            const onSlide=host!==document.body;
            insertCount++;
            if(onSlide){
              const off=(insertCount%6);
              el.style.position='absolute';
              el.style.left=(32+off*26)+'px';
              el.style.top=(28+off*22)+'px';
              el.style.zIndex=50;
            }
            host.appendChild(el);
            return el;
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
            applyAnim(name,dur,delay,ease,iter,trigger){
              if(!selected) return; pushUndo(); ensureAnimLib();
              const t=trigger||'load';
              ['animation-name','animation-duration','animation-delay','animation-timing-function','animation-iteration-count','animation-fill-mode','animation'].forEach(p=>selected.style.removeProperty(p));
              selected.removeAttribute('data-jiba-anim');
              if(t==='load'){
                selected.style.setProperty('animation-name', name);
                selected.style.setProperty('animation-duration', dur+'s');
                selected.style.setProperty('animation-delay', delay+'s');
                selected.style.setProperty('animation-timing-function', ease||'ease');
                selected.style.setProperty('animation-iteration-count', iter===0?'infinite':String(iter||1));
                selected.style.setProperty('animation-fill-mode','both');
              } else {
                selected.setAttribute('data-jiba-anim', JSON.stringify({name,dur,delay,ease,iter,t}));
                ensureAnimRuntime();
                if(window.__jibaAnimArm) window.__jibaAnimArm(selected);
              }
              selected.setAttribute('data-v4-anim', name);
              selected.setAttribute('data-v4-trigger', t);
              post({type:'dirty'}); emitSelection();
            },
            clearAnim(){
              if(!selected) return; pushUndo();
              ['animation-name','animation-duration','animation-delay','animation-timing-function','animation-iteration-count','animation-fill-mode','animation'].forEach(p=>selected.style.removeProperty(p));
              selected.removeAttribute('data-jiba-anim');
              selected.removeAttribute('data-v4-anim');
              selected.removeAttribute('data-v4-trigger');
              if(!document.querySelector('[data-jiba-anim]')){
                const rt=document.getElementById('jiba-anim-runtime'); if(rt) rt.remove();
              }
              post({type:'dirty'}); emitSelection();
            },
            previewAnim(){
              if(!selected) return;
              if(window.__jibaPlay && selected.hasAttribute('data-jiba-anim')){ window.__jibaPlay(selected); return; }
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
              placeIn(svg); select(svg); post({type:'dirty'});
            },
            insertNode(kind){
              pushUndo(); let el=null;
              if(kind==='textbox'){ el=document.createElement('div'); el.textContent='双击编辑文字'; el.style.cssText='padding:12px 16px;font-size:16px;min-width:120px;background:rgba(255,255,255,.9)'; }
              if(kind==='title'){ el=document.createElement('h2'); el.textContent='新标题'; el.style.cssText='font-size:28px;font-weight:800;margin:0'; }
              if(kind==='button'){ el=document.createElement('a'); el.href='javascript:void(0)'; el.textContent='点击这里'; el.style.cssText='display:inline-block;padding:10px 22px;background:#ff9900;color:#0f1115;border-radius:8px;font-weight:600;text-decoration:none'; }
              if(kind==='divider'){ el=document.createElement('hr'); el.style.cssText='border:none;border-top:2px solid #e2e6ec;margin:0;width:60%'; }
              if(kind==='card'){ el=document.createElement('div'); el.innerHTML='<div style="font-weight:700;margin-bottom:6px">卡片标题</div><div style="color:#5f6b7a">描述文字</div>'; el.style.cssText='background:#fff;border:1px solid #e2e6ec;border-radius:12px;padding:16px;max-width:320px;box-shadow:0 4px 16px rgba(0,0,0,.08)'; }
              if(kind==='icon'){ el=document.createElement('div'); el.textContent='⭐'; el.style.cssText='font-size:48px;line-height:1'; }
              if(el){ placeIn(el); select(el); post({type:'dirty'}); }
            },
            insertTable(rows,cols){
              pushUndo();
              const t=document.createElement('table'); t.style.borderCollapse='collapse';
              for(let r=0;r<rows;r++){ const tr=document.createElement('tr');
                for(let c=0;c<cols;c++){ const cell=document.createElement(r===0?'th':'td');
                  cell.textContent=r===0?('表头'+(c+1)):' '; cell.style.border='1px solid #94a3b8'; cell.style.padding='8px 12px';
                  if(r===0){ cell.style.background='#ff9900'; cell.style.color='#0f1115'; }
                  tr.appendChild(cell); }
                t.appendChild(tr); }
              placeIn(t); select(t); post({type:'dirty'});
            },
            insertImage(url){
              pushUndo();
              const img=document.createElement('img'); img.src=url; img.alt='图片'; img.style.maxWidth='240px';
              placeIn(img); select(img); post({type:'dirty'});
            },
            undo, redo, pptNav, pptGo,
            pptDup(){
              const slides=pptSlides();
              if(!slides.length){ post({type:'toast',msg:'未检测到幻灯片结构'}); return; }
              pushUndo();
              const cur=pptCur();
              const c=slides[cur].cloneNode(true);
              c.querySelectorAll('.j-handle').forEach(h=>h.remove());
              c.classList.remove('j-selected');
              c.removeAttribute('data-v4-ppt'); c.removeAttribute('data-v4-orig-opacity'); c.removeAttribute('data-v4-orig-pe');
              slides[cur].parentNode.insertBefore(c, slides[cur].nextSibling);
              detectPPT(); pptGo(cur+1);
              post({type:'dirty'});
            },
            pptDel(){
              const slides=pptSlides();
              if(!slides.length){ post({type:'toast',msg:'未检测到幻灯片结构'}); return; }
              if(slides.length<=1){ post({type:'toast',msg:'至少保留一页'}); return; }
              pushUndo();
              const cur=pptCur();
              slides[cur].remove();
              detectPPT(); pptGo(Math.min(cur, slides.length-2));
              post({type:'dirty'});
            },
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
              placeIn(c); select(c); post({type:'dirty'});
            },
            bringForward(){ if(!selected||!selected.nextElementSibling) return; pushUndo(); selected.parentNode.insertBefore(selected.nextElementSibling, selected); post({type:'dirty'}); },
            sendBackward(){ if(!selected||!selected.previousElementSibling) return; pushUndo(); selected.parentNode.insertBefore(selected, selected.previousElementSibling); post({type:'dirty'}); },
            bringToFront(){ if(!selected||!selected.parentNode) return; pushUndo(); selected.parentNode.appendChild(selected); post({type:'dirty'}); },
            sendToBack(){ if(!selected||!selected.parentNode) return; pushUndo(); selected.parentNode.insertBefore(selected, selected.parentNode.firstChild); post({type:'dirty'}); },
            toggleBold(){
              if(!selected) return; pushUndo();
              const cs=getComputedStyle(selected);
              const w=parseInt(cs.fontWeight)||400;
              selected.style.fontWeight = w>=600 ? '400' : '700';
              post({type:'dirty'}); emitSelection();
            },
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
            selectAll(){ select(document.body); },
            present(on){
              presentMode=!!on;
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
