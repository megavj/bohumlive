(() => {
  "use strict";
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];
  const page = document.body.dataset.page;
  const params = new URLSearchParams(location.search);
  const E = (v) =>
    String(v ?? "").replace(
      /[&<>"']/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
    );
  const uri = (file, args = {}) => "/" + file + (Object.keys(args).length ? "?" + new URLSearchParams(args) : "");
  const here = () => location.pathname + location.search;
  // 버튼을 눌렀다가 로그인 화면으로 온 손님에게만 이유를 한 줄 보여 준다.
  const loginReasons = {
    like: "좋아요를 누르려면 먼저 로그인해 주세요.",
    bookmark: "북마크하려면 먼저 로그인해 주세요.",
    follow: "채널을 팔로우하려면 먼저 로그인해 주세요.",
    report: "신고하려면 먼저 로그인해 주세요. 처리 결과는 알림으로 알려 드려요.",
  };
  const loginUrl = (returnTo = here(), why = "") => uri("login.html", { returnTo, ...(why ? { why } : {}) });
  const date = (v) =>
    v
      ? new Date(v).toLocaleString("ko-KR", { year: "numeric", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })
      : "";
  const statusNames = {
    unverified: "설계사 인증 전",
    pending: "인증 대기",
    supplement: "보완 필요",
    verified: "인증 완료",
    rejected: "반려",
    suspended: "이용 정지",
    withdrawn: "탈퇴한 회원",
  };
  const kindNames = { practice: "실무지식", career: "커리어", experience: "경험·자유", weekly: "운영팀 정리" };
  const scoreNames = ["수수료·시책", "교육", "전산", "심사·지급", "지점 분위기"];
  let sb,
    session = null,
    viewer = null,
    mine = null,
    channels = [],
    companies = [],
    current = null,
    renderId = 0,
    toastTimer,
    proofPreview;
  const isActive = () => !!viewer && !["suspended", "withdrawn"].includes(viewer.status);
  const isOwner = () => viewer?.role === "owner" && isActive() && viewer.verification_exempt !== false;
  const isAdmin = () => ["admin", "owner"].includes(viewer?.role) && isActive() && viewer.can_admin !== false;
  const validVerification = (p) => p?.status === "verified" && Date.parse(p.verified_until) > Date.now();
  const isVerified = () => isOwner() || (validVerification(viewer) && viewer.can_write !== false);
  const canReadMember = () => isVerified() || isAdmin();
  const statusLabel = (p = viewer) =>
    isOwner()
      ? "대표 관리자 · 모든 권한"
      : p?.status === "verified" && !validVerification(p)
        ? "인증 기간 만료 · 재인증 필요"
        : statusNames[p?.status] || "계정 확인 중";
  const sampleBadge = (p) => (p?.is_sample ? '<span class="tag sample-badge" title="정식 공개 전 화면 확인용으로 만든 글입니다">견본 글</span>' : "");
  const icon = (name) => {
    const paths = {
      search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
      heart:
        '<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z"/>',
      comment:
        '<path d="M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.4 8.4 0 0 1 3.8-.9h.5a8.5 8.5 0 0 1 8 8Z"/>',
      bookmark: '<path d="M19 21l-7-4-7 4V3h14z"/>',
      bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/>',
      edit: '<path d="m16 3 5 5-12 12-6 1 1-6zM14 5l5 5"/>',
      share: '<path d="M12 16V3m-5 5 5-5 5 5M4 14v7h16v-7"/>',
      lock: '<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4"/>',
      eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
      more: '<circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/>',
      link: '<path d="M10 14a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1M14 10a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/>',
    };
    return `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.comment}</svg>`;
  };
  const btn = (label, action, attrs = "", primary = false) =>
    `<button type="button" class="btn ${primary ? "btn-primary" : ""}" data-do="${E(action)}" ${attrs}>${label}</button>`;
  const empty = (title = "아직 올라온 글이 없어요.", sub = "동료와 나누고 싶은 경험이나 질문을 남겨 주세요.") =>
    `<div class="empty"><strong>${E(title)}</strong>${E(sub)}</div>`;
  function notify(message) {
    $("#toast").textContent = message;
    $("#toast").hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => ($("#toast").hidden = true), 4500);
  }
  function safeError(error) {
    const msg = String(error?.message || "");
    if (/permission denied/i.test(msg)) return "로그인한 뒤 이용할 수 있어요.";
    if (/invalid input syntax|uuid/i.test(msg)) return "주소가 올바르지 않아요. 목록에서 다시 골라 주세요.";
    if (/fetch|network|Failed|Load failed/i.test(msg))
      return "연결하지 못했어요. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.";
    if (/rate|over_email_send_rate_limit|429/i.test(msg))
      return "요청이 많아 잠시 처리하지 못했어요. 몇 분 뒤 다시 시도하거나 Google로 로그인해 주세요.";
    if (/Email address not authorized|email_address_not_authorized/i.test(msg))
      return "기본 이메일 발송기는 사전 등록된 운영자 이메일만 지원합니다. 일반 가입 연결을 준비하고 있습니다.";
    if (/provider.*enabled|Unsupported provider/i.test(msg))
      return "이 로그인 방식은 아직 연결되지 않았어요. 다른 로그인 방법을 이용해 주세요.";
    if (/JWT|expired|session|로그인/i.test(msg))
      return "로그인이 만료되었거나 로그인이 필요해요. 다시 로그인해 주세요.";
    // 서버의 안내는 모두 한국어로 쓴다. 영어 내부 오류는 그대로 보여 주지 않는다.
    if (/[가-힣]/.test(msg) && msg.length < 260 && !/eyJ|secret|token|password|service_role/i.test(msg)) return msg;
    return "요청을 처리하지 못했어요. 새로고침 후 다시 시도해 주세요.";
  }
  async function read(scope, args = {}) {
    const { data, error } = await sb.rpc("bl_read", { p_scope: scope, p_args: args });
    if (error) throw error;
    if (data?.viewer !== undefined) viewer = data.viewer;
    return data || {};
  }
  async function act(action, payload = {}) {
    const { data, error } = await sb.rpc("bl_action", { p_action: action, p_payload: payload });
    if (error) throw error;
    return data || {};
  }
  let fieldSeq = 0;
  function field(name, label, type = "text", value = "", extra = "") {
    const fid = name + "-" + ++fieldSeq;
    return `<div class="field"><label for="${E(fid)}">${E(label)}</label><input id="${E(fid)}" name="${E(name)}" type="${E(type)}" value="${E(value)}" ${extra}></div>`;
  }
  function area(name, label, value = "", extra = "") {
    const fid = name + "-" + ++fieldSeq;
    return `<div class="field"><label for="${E(fid)}">${E(label)}</label><textarea id="${E(fid)}" name="${E(name)}" ${extra}>${E(value)}</textarea></div>`;
  }
  function select(name, label, options, value = "", extra = "") {
    const fid = name + "-" + ++fieldSeq;
    return `<div class="field"><label for="${E(fid)}">${E(label)}</label><select id="${E(fid)}" name="${E(name)}" ${extra}>${options.map((o) => `<option value="${E(o[0])}" ${String(o[0]) === String(value) ? "selected" : ""}>${E(o[1])}</option>`).join("")}</select></div>`;
  }
  const formEnd = (label = "저장") =>
    `<p class="error field-error" data-form-error role="alert"></p><div class="form-actions"><button type="submit" class="btn btn-primary" data-testid="submit">${E(label)}</button></div>`;
  const companyOptions = () => [
    ["", "회사를 선택해 주세요"],
    ...companies.filter((c) => c.enabled !== false).map((c) => [c.id, c.name]),
    ["custom", "직접 입력"],
  ];
  function layout() {
    const active =
      page === "home"
        ? "home"
        : ["channels", "channel", "write", "post", "search"].includes(page)
          ? "channels"
          : page === "company"
            ? "company"
            : "";
    // 글쓰기는 머리줄의 연필 하나로만 들어간다(채널 화면에서는 그 채널이 미리 골라진다).
    const writeHref = uri("write.html", page === "channel" && params.get("id") ? { channel: params.get("id") } : {});
    const unread = Number(viewer?.unread_count) || 0;
    const tools = `<a class="tool-btn tool-search" href="/search.html" aria-label="검색" data-testid="header-search-link">${icon("search")}</a>${page === "write" || page === "login" ? "" : `<a class="tool-btn tool-write" href="${E(writeHref)}" aria-label="글쓰기" title="글쓰기" data-testid="header-write">${icon("edit")}<span class="tool-label">글쓰기</span></a>`}${
      session
        ? `<div class="header-user" data-testid="header-user"><a class="tool-btn notification-link" href="/notifications.html" aria-label="${unread ? `알림 ${unread}개 안 읽음` : "알림"}" title="알림">${icon("bell")}${unread ? `<span class="notification-count" data-testid="unread-count">${unread > 99 ? "99+" : unread}</span>` : ""}</a><a class="header-name" href="/me.html" title="내 정보">${E(displayName())}님</a><span class="header-sep" aria-hidden="true">·</span><button type="button" class="header-logout" data-do="logout" data-testid="header-logout">로그아웃</button></div>`
        : page === "login"
          ? ""
          : `<a class="header-login" href="${E(loginUrl())}">로그인·가입</a>`
    }`;
    $("#header").innerHTML =
      `<header class="site-header"><div class="header-inner"><div class="topbar"><a class="wordmark" href="/index.html" aria-label="보험라이브 홈"><picture><source media="(prefers-reduced-motion: reduce)" srcset="/assets/logo-live-still.png?v=20261109"><source media="(max-width: 799px)" srcset="/assets/logo-live-m.gif?v=20261109b"><img class="wm-logo" src="/assets/logo-live.gif?v=20261109b" alt="보험라이브" width="320" height="96" decoding="async" fetchpriority="high"></picture></a><nav class="primary-nav" aria-label="주 메뉴"><a class="${active === "home" ? "active" : ""}" href="/index.html">홈</a><a class="${active === "channels" ? "active" : ""}" href="/channels.html">채널</a><a class="${active === "company" ? "active" : ""}" href="/company.html">보험사 리뷰</a>${isAdmin() ? `<a class="${page === "admin" ? "active" : ""}" href="/admin/" data-testid="admin-nav">관리자</a>` : ""}</nav><form class="header-search" action="/search.html" role="search"><input aria-label="검색어" name="q" placeholder="궁금한 내용 검색" value="${page === "search" ? E(params.get("q") || "") : ""}" maxlength="100"><button aria-label="검색">${icon("search")}</button></form><div class="header-tools">${tools}</div></div>${isOwner() ? '<p class="status-banner" data-testid="owner-permissions">대표 관리자 · 모든 권한 · 인증 면제</p>' : ""}</div></header>`;
    $("#footer").innerHTML =
      `<footer class="site-footer"><div class="footer-logo">보험<b style="color:var(--accent)">라이브</b></div><nav class="footer-links" aria-label="서비스 정책"><a href="/terms.html">이용약관</a><a href="/privacy.html">개인정보처리방침</a><a href="/rules.html">커뮤니티 운영정책</a><a href="/help.html">이용 도움말·권리침해 신고</a></nav><p class="footer-note">보험라이브는 설계사의 경험과 실무 지식을 나누는 공간입니다. 회원의 글은 개인의 의견이며 회사의 공식 입장이나 보험상품 가입 권유가 아닙니다. 고객정보·주민등록번호·개인 연락처를 게시하지 마세요.</p><p class="footer-note">공개 준비 중 · 검색 노출을 차단하고 있습니다.</p></footer>`;
    // 오른쪽 칸: 안내 상자·글쓰기 버튼을 두지 않는다. 목록·글 화면(PC)에서만 '인기 글' 제목 목록을 채운다.
    const mode = page === "admin" ? "admin" : page === "home" ? "wide" : ["channel", "post", "search"].includes(page) ? "aside" : "narrow";
    document.body.dataset.layout = mode;
    $("#sidebar").innerHTML = "";
    $("#sidebar").hidden = mode !== "aside";
    $("#main").classList.toggle("admin-main", page === "admin");
  }
  // PC 오른쪽 칸: '인기 글' 제목 목록만 둔다(본문을 먼저 그린 뒤 따로 채운다).
  async function fillAside(stamp) {
    if (document.body.dataset.layout !== "aside" || !sb || !window.matchMedia("(min-width: 800px)").matches) return;
    try {
      const { data, error } = await sb.rpc("bl_read", { p_scope: "best", p_args: {} });
      if (error || stamp !== renderId) return;
      const list = (data?.best || []).filter((p) => p.id !== params.get("id")).slice(0, 10);
      $("#sidebar").innerHTML = list.length
        ? `<section class="side-best" data-testid="side-best"><h2>인기 글</h2><ol>${list.map((p, i) => `<li><a href="${uri("post.html", { id: p.id })}"><span class="side-rank">${i + 1}</span><span class="side-title">${E(p.title)}</span></a></li>`).join("")}</ol></section>`
        : "";
    } catch {}
  }
  // 로그인했지만 아직 글을 쓸 수 없는 회원에게만 보이는 얇은 한 줄 안내
  function verifyStrip() {
    if (!session || !viewer || isVerified() || isAdmin()) return "";
    const s = viewer.status;
    const [text, label, href] =
      s === "suspended"
        ? ["이용 정지 상태예요. 공개 글만 읽을 수 있어요.", "안내 보기", "/help.html"]
        : s === "pending"
          ? ["설계사 인증을 심사하고 있어요. 결과는 알림으로 알려 드려요.", "신청 내용 보기", "/me.html"]
          : s === "supplement"
            ? ["인증 신청에 보완이 필요해요.", "보완하기", "/verify.html"]
            : s === "rejected"
              ? ["인증 신청이 반려됐어요. 내용을 확인하고 다시 신청해 주세요.", "다시 신청", "/verify.html"]
              : s === "verified"
                ? ["인증 기간이 끝났어요. 다시 인증하면 글·댓글을 쓸 수 있어요.", "재인증하기", "/verify.html"]
                : ["설계사 인증을 마치면 글·댓글을 쓸 수 있어요.", "인증하기", "/verify.html"];
    return `<p class="verify-strip" data-testid="verify-strip"><span>${E(text)}</span><a href="${href}">${E(label)}</a></p>`;
  }
  function authorization(kind = "verified") {
    if (!session) {
      location.replace(loginUrl());
      return '<div class="loading" role="status">로그인 화면으로 이동합니다.</div>';
    }
    if (kind === "admin" && !isAdmin())
      return empty("관리자만 사용할 수 있어요.", "권한은 서버에서 확인합니다. 내 정보에서 현재 상태를 확인해 주세요.");
    if (kind === "verified" && !isVerified())
      return `<section class="section"><h1>설계사 인증 후 이용할 수 있어요</h1><p class="notice">현재 상태: ${E(statusLabel())}${mine?.profile?.review_reason ? `<br>${E(mine.profile.review_reason)}` : ""}</p>${viewer?.status === "suspended" ? '<p>정지 상태에서는 공개 글만 읽을 수 있습니다.</p><a class="btn" href="/help.html">운영 안내</a>' : '<a class="btn btn-primary" href="/verify.html">인증 신청·보완하기</a>'}</section>`;
    return "";
  }
  // NOW·HOT 기준(숫자만 바꾸면 됨) — HOT: 좋아요 5개 이상 또는 댓글 10개 이상 / NOW: 24시간 안에 올라와 댓글 3개 이상 또는 좋아요 2개 이상
  const HEAT = { hot: { likes: 5, comments: 10 }, now: { hours: 24, likes: 2, comments: 3 } };
  function heat(p) {
    const likes = Number(p.likes) || 0,
      cm = Number(p.comment_count) || 0;
    if (p.pinned || (p.status && p.status !== "published")) return "";
    if (likes >= HEAT.hot.likes || cm >= HEAT.hot.comments) return '<i class="heat heat-hot" title="반응이 많은 글">HOT</i>';
    if (Date.now() - Date.parse(p.created_at) < HEAT.now.hours * 3600000 && (likes >= HEAT.now.likes || cm >= HEAT.now.comments))
      return '<i class="heat heat-now" title="지금 이야기 중인 글">NOW</i>';
    return "";
  }
  const timeTag = (v, cls = "item-time") =>
    `<time class="${cls}" datetime="${E(v || "")}" title="${E(date(v))}"><span class="sr-only">작성시간 </span>${E(ago(v))}</time>`;
  const markButton = (p, cls = "item-mark") =>
    `<button type="button" class="${cls}" data-do="toggle" data-target="post" data-kind="bookmark" data-id="${E(p.id)}" aria-pressed="${!!p.bookmarked}" aria-label="저장" title="저장">${icon("bookmark")}</button>`;
  // 목록 한 줄: [NOW/HOT·채널] 제목 → 본문 앞 1~2줄 → 회사·닉네임 → 조회수·좋아요·댓글 → 작성시간 → 저장
  // mixed: 여러 채널이 섞인 목록(채널 이름을 작게 보여 줌), compact: 본문 미리보기 없이
  function feed(post, opts = {}) {
    const href = uri("post.html", { id: post.id });
    if (post.pinned)
      return `<article class="item item-notice" data-testid="post-item"><a class="notice-row" href="${href}"><span class="notice-mark">공지</span><span class="notice-title">${E(post.title)}</span></a></article>`;
    const top = `${heat(post)}${opts.mixed ? `<span class="item-channel">${E(post.channel_name || "")}</span>` : ""}${post.status && post.status !== "published" ? '<span class="tag hidden-tag">숨김</span>' : ""}`;
    return `<article class="item" data-testid="post-item"><a class="item-main" href="${href}">${top ? `<span class="item-top">${top}</span>` : ""}<h3 class="item-title">${E(post.title)}</h3>${opts.compact || !post.body ? "" : `<p class="item-pre">${E(String(post.body).slice(0, 160))}</p>`}</a><div class="item-sub"><span class="item-name">${E(post.author_display || "보험라이브 운영팀")}</span><span class="item-stats">${stat("eye", "조회수", post.views)}${stat("heart", "좋아요", post.likes)}${stat("comment", "댓글", post.comment_count)}</span>${timeTag(post.created_at)}${markButton(post)}</div></article>`;
  }
  const feeds = (posts, opts = {}) => (posts?.length ? posts.map((p) => feed(p, opts)).join("") : empty());
  const channelDisc = (c) => `<span class="topic-disc ${E(c.slug)}">${E(c.name?.slice(0, 1) || "보")}</span>`;
  // 짧은 시간 표시: 방금 · 5분 · 2시간 · 어제 · 3일 · 11.07 · 2025.11.07
  const ago = (v) => {
    if (!v) return "";
    const t = new Date(v),
      now = new Date(),
      min = Math.floor((now - t) / 60000);
    if (min < 1) return "방금";
    if (min < 60) return `${min}분`;
    if (min < 1440) return `${Math.floor(min / 60)}시간`;
    if (min < 2880) return "어제";
    if (min < 10080) return `${Math.floor(min / 1440)}일`;
    const md = `${String(t.getMonth() + 1).padStart(2, "0")}.${String(t.getDate()).padStart(2, "0")}`;
    return t.getFullYear() === now.getFullYear() ? md : `${t.getFullYear()}.${md}`;
  };
  // 큰 숫자는 짧게: 1,234 · 1.2만
  const num = (v) => {
    const n = Number(v) || 0;
    return n >= 10000 ? `${(n / 10000).toFixed(n >= 100000 ? 0 : 1).replace(/\.0$/, "")}만` : n.toLocaleString("ko-KR");
  };
  // 아이콘 + 숫자(화면 읽기 프로그램에는 이름까지 읽어 준다)
  const stat = (name, label, value) =>
    `<span class="stat stat-${name}" title="${label} ${num(value)}">${icon(name)}<span class="sr-only">${label}</span>${num(value)}</span>`;
  // 공지는 맨 위에 한 줄. 여러 개면 첫 줄만 보이고 '+n'을 누르면 나머지가 펼쳐진다.
  function noticeLine(list = []) {
    if (!list.length) return "";
    const row = (n) =>
      `<a class="notice-row" href="${uri("post.html", { id: n.id })}"><span class="notice-mark">공지</span><span class="notice-title">${E(n.title)}</span></a>`;
    if (list.length === 1) return `<div class="notice-line" data-testid="notice-line">${row(list[0])}</div>`;
    return `<details class="notice-line" data-testid="notice-line"><summary>${row(list[0])}<span class="notice-count" title="공지 ${list.length - 1}개 더 보기">+${list.length - 1}</span></summary>${list.slice(1).map(row).join("")}</details>`;
  }
  async function home() {
    const d = await read("home", { v: "3" });
    channels = d.channels || [];
    const byId = Object.fromEntries(channels.map((c) => [c.id, c]));
    const boxes = (d.boxes || []).filter((b) => byId[b.channel_id]);
    const filled = boxes.filter((b) => b.posts.length),
      quiet = boxes.filter((b) => !b.posts.length);
    const best = d.best || [];
    const bestRow = (p) =>
      `<li class="best-row" data-testid="best-item"><a class="best-channel" href="${uri("channel.html", { id: p.channel_id })}">${E(p.channel_name || "")}</a><a class="best-title" href="${uri("post.html", { id: p.id })}">${E(p.title)}</a><span class="best-info">${stat("heart", "좋아요", p.likes)}${stat("comment", "댓글", p.comment_count)}</span></li>`;
    const box = (b) => {
      const c = byId[b.channel_id];
      return `<section class="box" data-testid="home-box"><div class="box-head"><h2><a href="${uri("channel.html", { id: c.id })}">${E(c.name)}</a></h2><a class="box-more" href="${uri("channel.html", { id: c.id })}" aria-label="${E(c.name)} 더보기">더보기</a></div><ul class="box-list">${b.posts.map((p) => `<li><a href="${uri("post.html", { id: p.id })}">${E(p.title)}</a>${stat("eye", "조회수", p.views)}</li>`).join("")}</ul></section>`;
    };
    return `<form class="home-search" action="/search.html" role="search"><input aria-label="검색어" name="q" placeholder="궁금한 내용을 검색해 보세요" maxlength="100"><button aria-label="검색">${icon("search")}</button></form>${noticeLine(d.notices)}${verifyStrip()}<section class="best" data-testid="home-best"><div class="box-head"><h1>인기 글</h1><a class="box-more" href="/channel.html?sort=popular" aria-label="인기 글 더보기">더보기</a></div>${best.length ? `<ol class="best-list">${best.map(bestRow).join("")}</ol>` : empty()}</section><div class="boxes" data-testid="home-boxes">${filled.map(box).join("")}</div>${quiet.length ? `<p class="quiet-channels" data-testid="quiet-channels"><span>첫 글을 기다리는 채널</span>${quiet.map((b) => `<a href="${uri("channel.html", { id: b.channel_id })}">${E(byId[b.channel_id].name)}</a>`).join("")}</p>` : ""}`;
  }
  async function channelList() {
    const d = await read("channels");
    channels = d.channels || [];
    const follow = params.get("filter") === "following";
    const list = follow ? channels.filter((c) => c.following) : channels;
    return `<section class="explore"><h1>채널 탐색</h1><p class="muted">관심 있는 주제를 팔로우하고 동료의 이야기를 만나 보세요.</p><nav class="chips"><a class="chip ${!follow ? "active" : ""}" href="/channels.html">모든 채널</a><a class="chip ${follow ? "active" : ""}" href="/channels.html?filter=following">팔로우한 채널</a></nav><div class="channel-cards">${list.map((c) => `<article class="channel-card">${channelDisc(c)}<div class="channel-card-info"><h2><a href="${uri("channel.html", { id: c.id })}">${E(c.name)}</a>${c.anonymous ? ' <span class="tag anon-tag">완전 익명</span>' : ""}</h2><p>${E(c.description)}</p><p class="follow-count" data-followers="${E(c.id)}" data-base="${Number(c.followers) || 0}" data-first="${!!c.following}">팔로워 ${Number(c.followers) || 0}명</p></div><button type="button" class="follow-small" data-do="toggle" data-target="channel" data-kind="follow" data-id="${E(c.id)}" aria-pressed="${!!c.following}" data-on="팔로잉" data-off="팔로우">${c.following ? "팔로잉" : "팔로우"}</button></article>`).join("")}</div>${!list.length ? empty("아직 팔로우한 채널이 없어요.", "모든 채널에서 관심 있는 주제를 선택해 주세요.") : ""}</section>`;
  }
  // 채널 바로가기 줄: 전체 · 인기 · 채널들 · 채널 탐색(옆으로 밀어서 이동)
  function channelChips(activeId, sort) {
    const on = (flag) => (flag ? "active" : "");
    return `<nav class="chan-chips" aria-label="채널 바로가기" data-testid="chan-chips"><a class="chip ${on(!activeId && sort !== "popular")}" href="/channel.html">전체</a><a class="chip ${on(!activeId && sort === "popular")}" href="/channel.html?sort=popular">인기</a>${channels
      .filter((c) => c.enabled !== false)
      .map((c) => `<a class="chip ${on(c.id === activeId)}" href="${uri("channel.html", { id: c.id })}">${E(c.name)}</a>`)
      .join("")}<a class="chip chip-more" href="/channels.html">채널 탐색 ›</a></nav>`;
  }
  async function postList() {
    const q = params.get("q") || "";
    let id = params.get("id") || "";
    const cd = await read("channels");
    channels = cd.channels || [];
    if (!id && params.get("channel")) id = channels.find((c) => c.slug === params.get("channel"))?.id || "";
    const channel = channels.find((c) => c.id === id);
    const isSearch = page === "search";
    if (id && !channel && !isSearch) return empty("채널을 찾을 수 없어요.", "채널 목록에서 다시 골라 주세요.");
    const sort = params.get("sort") === "popular" ? "popular" : "latest";
    const listArgs = { ...(id ? { channel_id: id } : {}), ...(q ? { q } : {}), sort, limit: 20 };
    const d = await read("posts", listArgs);
    const posts = d.posts || [];
    const opts = { mixed: !channel };
    current = { list: { args: listArgs, offset: posts.length, opts } };
    const sortLink = (key, label) =>
      `<a class="${sort === key ? "active" : ""}" ${sort === key ? 'aria-current="true"' : ""} href="${uri(isSearch ? "search.html" : "channel.html", { ...(id ? { id } : {}), ...(q ? { q } : {}), ...(key === "popular" ? { sort: "popular" } : {}) })}">${label}</a>`;
    const sorter = `<nav class="list-sort" aria-label="정렬" data-testid="list-sort">${sortLink("latest", "최신순")}${sortLink("popular", "추천순")}</nav>`;
    const head = isSearch
      ? `<header class="list-head"><div class="list-title"><h1>검색 결과</h1>${q ? sorter : ""}</div><form class="search-form" action="/search.html"><input name="q" aria-label="검색할 내용" value="${E(q)}" maxlength="100" placeholder="궁금한 내용을 검색하세요" required><button class="btn" type="submit">검색</button></form><p class="list-desc">${q ? `“${E(q)}” 검색 결과 ${posts.length >= 20 ? "20개 이상" : `${posts.length}개`}` : "검색어를 입력해 주세요."}</p></header>`
      : `${channelChips(id, sort)}<header class="list-head"><div class="list-title"><h1>${E(channel?.name || (sort === "popular" ? "인기 글" : "전체 글"))}${channel?.anonymous ? ' <span class="tag anon-tag">완전 익명</span>' : ""}</h1>${channel ? `<button type="button" class="follow-chip" data-do="toggle" data-target="channel" data-kind="follow" data-id="${E(channel.id)}" aria-pressed="${!!channel.following}" data-on="팔로잉" data-off="팔로우">${channel.following ? "팔로잉" : "팔로우"}</button>` : ""}${sorter}</div>${channel?.description ? `<p class="list-desc">${E(channel.description)}</p>` : ""}${channel?.anonymous ? '<p class="list-desc">이 채널의 글과 댓글은 회사명·닉네임 없이 ‘익명’으로만 보여요. 운영자는 신고 처리 때만 기록을 남기고 작성자를 확인합니다.</p>' : ""}</header>${verifyStrip()}`;
    return `${head}${isSearch && !q ? empty("궁금한 내용을 찾아보세요.", "제목과 공개 범위에 맞는 본문을 검색합니다.") : `<div class="item-list" data-post-list>${feeds(posts, opts)}</div>${posts.length >= 20 ? `<p class="more-wrap">${btn("더 보기", "more-posts", 'data-testid="more-posts"')}</p>` : ""}`}`;
  }
  // ⋯ 메뉴: 링크 복사·신고·수정·삭제처럼 가끔 쓰는 기능을 접어 둔다.
  const moreMenu = (items, label = "더보기") =>
    `<details class="more-menu"><summary aria-label="${label}" title="${label}">${icon("more")}</summary><div class="more-list">${items.filter(Boolean).join("")}</div></details>`;
  // 손님·인증 전 회원에게 보이는 짧은 잠금 안내 한 줄
  function lockBar(text) {
    const action =
      viewer?.status === "suspended"
        ? '<a class="btn btn-small" href="/help.html">이용 정지 안내</a>'
        : viewer?.status === "pending"
          ? '<a class="btn btn-small" href="/me.html">심사 중</a>'
          : verifyLink("btn btn-primary btn-small");
    return `<div class="guest-lock lock-bar" data-testid="guest-lock">${icon("lock")}<span>${E(text)}</span>${action}</div>`;
  }
  // 같은 기기에서 새로고침을 반복해도 조회수는 한 번만 올린다.
  function firstView(id) {
    try {
      const seen = JSON.parse(sessionStorage.getItem("bl_viewed") || "[]");
      if (seen.includes(id)) return false;
      sessionStorage.setItem("bl_viewed", JSON.stringify([...seen, id].slice(-200)));
    } catch {}
    return true;
  }
  // 글 맨 아래: 같은 채널의 다른 글(본문을 먼저 그린 뒤 따로 채운다)
  async function fillMorePosts(stamp) {
    const slot = $("[data-more-posts]");
    if (!slot || !sb) return;
    try {
      const { data, error } = await sb.rpc("bl_read", { p_scope: "posts", p_args: { channel_id: slot.dataset.channel, limit: 8 } });
      if (error || stamp !== renderId || !slot.isConnected) return;
      const list = (data?.posts || []).filter((x) => x.id !== slot.dataset.post && !x.pinned).slice(0, 5);
      if (!list.length) return;
      slot.innerHTML = `<div class="box-head"><h2>‘${E(slot.dataset.name)}’ 채널의 다른 글</h2><a class="box-more" href="${uri("channel.html", { id: slot.dataset.channel })}" aria-label="${E(slot.dataset.name)} 채널 더보기">더보기</a></div><div class="item-list">${feeds(list)}</div>`;
      slot.hidden = false;
    } catch {}
  }
  async function post() {
    const id = params.get("id");
    if (!id) return empty("글을 선택해 주세요.", "홈이나 채널에서 읽을 글을 선택할 수 있어요.");
    const d = await read("post", { id, ...(firstView(id) ? { view: "1" } : {}) });
    current = d;
    const p = d.post;
    if (!p)
      return d.unavailable_reason === "not_found"
        ? empty("글을 찾을 수 없어요.", "주소가 바뀌었거나 삭제된 글이에요. 채널에서 다른 글을 골라 주세요.")
        : `<section class="section"><h1>${d.unavailable_reason === "temporary_hidden" ? "운영 검토를 위해 임시 가림한 글입니다" : "글을 표시할 수 없어요"}</h1><p class="notice">이 글은 삭제되었거나 신고 접수에 따른 운영 검토로 가려졌습니다. 임시조치는 접수 후 최대 30일 안에 검토합니다.${d.hidden_until ? `<br>검토 예정: ${E(date(d.hidden_until))}` : ""}</p><a class="btn" href="/channel.html">다른 글 보기</a><a class="btn" href="/help.html">신고·이의신청 안내</a></section>`;
    const following = !!mine?.follows?.includes(p.channel_id);
    const menu = moreMenu(
      [
        `<button type="button" data-do="share" data-testid="post-copy">${icon("link")} 링크 복사</button>`,
        p.is_mine && isVerified() ? `<a href="${uri("write.html", { id: p.id })}" data-testid="post-edit">${icon("edit")} 수정</a>` : "",
        p.is_mine && isVerified() ? `<button type="button" data-do="post-delete" data-id="${E(p.id)}">삭제</button>` : "",
        p.is_mine ? "" : `<button type="button" data-do="report" data-target="post" data-id="${E(p.id)}">신고</button>`,
      ],
      "글 메뉴 더보기",
    );
    const header = `<header class="post-header"><div class="breadcrumb"><a href="/channels.html">채널</a><span>›</span><a href="${uri("channel.html", { id: p.channel_id })}">${E(p.channel_name)}</a>${p.anonymous ? '<span class="tag anon-tag">완전 익명</span>' : ""}<span class="crumb-dot" aria-hidden="true">·</span><button type="button" class="crumb-follow" data-do="toggle" data-target="channel" data-kind="follow" data-id="${E(p.channel_id)}" aria-pressed="${following}" data-on="팔로잉" data-off="팔로우">${following ? "팔로잉" : "팔로우"}</button></div><h1>${E(p.title)}</h1><p class="post-author"><span class="company-name">${E(p.author_display)}</span></p><div class="post-info">${timeTag(p.created_at, "post-time")}${stat("eye", "조회수", p.views)}${stat("comment", "댓글", p.comment_count)}<span class="post-tools">${markButton(p, "tool-mark").replace("<button", '<button data-testid="post-bookmark"')}${menu}</span></div></header>`;
    const band =
      p.status && p.status !== "published"
        ? `<div class="status-band" data-testid="status-band"><b>${p.status === "hidden" ? "숨김 상태인 글" : "삭제된 글"}</b> — 다른 회원에게는 보이지 않아요.${p.is_mine && p.status === "hidden" ? `<br>운영 조치에 의견이 있으면 이의신청을 남겨 주세요. ${btn("내 글 조치에 이의신청", "appeal", `data-target="post" data-id="${E(p.id)}" data-testid="appeal-button"`)}` : ""}</div>`
        : "";
    const company = p.company_id
      ? `<p class="post-company"><a href="${uri("company.html", { id: p.company_id })}" data-testid="post-company"><span class="muted">관련 회사</span> ${E(p.company_name)} ›</a></p>`
      : "";
    const actions = `<div class="post-actions"><button type="button" data-do="toggle" data-target="post" data-kind="like" data-id="${E(p.id)}" aria-pressed="${!!p.liked}" ${p.is_mine ? 'disabled title="내 글에는 좋아요를 누를 수 없어요"' : ""} data-testid="post-like">${icon("heart")} 좋아요 <span data-count="${Number(p.likes) || 0}">${num(p.likes)}</span></button><a class="post-comment-link" href="#comments">${icon("comment")} 댓글 ${num(p.comment_count)}</a><button type="button" data-do="share" class="share-button" aria-label="공유(글 링크 복사)" title="공유(글 링크 복사)">${icon("share")}</button></div>`;
    return `<article class="post" data-testid="post">${header}${band}<div class="post-body body-text" data-testid="post-body">${E(p.body)}</div>${p.is_truncated ? lockBar("뒷부분은 설계사 인증 회원만 볼 수 있어요.") : ""}${company}${actions}${commentsSection(d)}<section class="more-posts" data-more-posts data-channel="${E(p.channel_id)}" data-post="${E(p.id)}" data-name="${E(p.channel_name)}" data-testid="more-posts-list" hidden></section></article>`;
  }
  // 댓글 정렬: 추천순(좋아요 많은 순, 같으면 먼저 쓴 순) · 등록순 · 최신순. 고른 값은 이 기기에 기억한다.
  const commentSorts = [
    ["best", "추천순"],
    ["oldest", "등록순"],
    ["latest", "최신순"],
  ];
  function commentSort() {
    try {
      const v = localStorage.getItem("bl_comment_sort");
      if (commentSorts.some(([k]) => k === v)) return v;
    } catch {}
    return "best";
  }
  function orderComments(comments, sort) {
    const t = (c) => Date.parse(c.created_at) || 0;
    const roots = comments
      .filter((c) => !c.parent_id)
      .sort((a, b) =>
        sort === "latest" ? t(b) - t(a) : sort === "best" ? (Number(b.likes) || 0) - (Number(a.likes) || 0) || t(a) - t(b) : t(a) - t(b),
      );
    // 대댓글은 언제나 원댓글 바로 아래에 쓴 순서대로
    return roots.flatMap((c) => [c, ...comments.filter((x) => x.parent_id === c.id).sort((a, b) => t(a) - t(b))]);
  }
  // 댓글 한 개: 회사·닉네임 → 내용 → 작성일·좋아요·대댓글·⋯(신고·수정·삭제)
  function commentHTML(c) {
    const menu = moreMenu(
      [
        c.is_mine && isVerified() ? `<button type="button" data-do="comment-edit" data-id="${E(c.id)}">${icon("edit")} 수정</button>` : "",
        c.is_mine && isVerified() ? `<button type="button" data-do="comment-delete" data-id="${E(c.id)}">삭제</button>` : "",
        c.is_mine ? "" : `<button type="button" data-do="report" data-target="comment" data-id="${E(c.id)}">신고</button>`,
      ],
      "댓글 메뉴 더보기",
    );
    return `<article class="comment-item ${c.parent_id ? "comment-reply" : ""}" id="comment-${E(c.id)}" data-testid="comment-item"><div class="comment-author">${E(c.author_display)}${c.is_mine ? ' <span class="author-badge">내 댓글</span>' : ""}</div><p class="body-text">${E(c.body)}</p><div class="comment-meta">${timeTag(c.created_at, "comment-time")}<button type="button" data-do="toggle" data-target="comment" data-kind="like" data-id="${E(c.id)}" aria-pressed="${!!c.liked}" aria-label="좋아요" ${c.is_mine ? 'disabled title="내 댓글에는 좋아요를 누를 수 없어요"' : 'title="좋아요"'}>${icon("heart")}<span data-count="${Number(c.likes) || 0}">${num(c.likes)}</span></button>${!c.parent_id && isVerified() ? `<button type="button" data-do="reply" data-id="${E(c.id)}">${icon("comment")}대댓글</button>` : ""}<span class="comment-tools">${menu}</span></div><div data-reply-slot="${E(c.id)}"></div></article>`;
  }
  const commentListHTML = (d) => {
    const list = orderComments(d.comments || [], commentSort());
    return list.length ? list.map(commentHTML).join("") : empty("아직 동료의 댓글이 없어요.", "첫 경험이나 의견을 남겨 주세요.");
  };
  function commentsSection(d) {
    const p = d.post,
      sort = commentSort();
    const sorter =
      canReadMember() && (d.comments || []).filter((c) => !c.parent_id).length > 1
        ? `<div class="comment-sort" role="group" aria-label="댓글 정렬" data-testid="comment-sort">${commentSorts.map(([k, label]) => `<button type="button" data-do="comment-sort" data-sort="${k}" class="${sort === k ? "active" : ""}" aria-pressed="${sort === k}">${label}</button>`).join("")}</div>`
        : "";
    // 입력칸은 한 줄로 두었다가 누르면 커지고 [취소][등록]이 나온다.
    const form = isVerified()
      ? `<form data-form="comment" class="comment-form"><input type="hidden" name="post_id" value="${E(p.id)}"><label class="sr-only" for="comment-body">댓글</label><textarea id="comment-body" name="body" rows="1" placeholder="좋은 댓글은 응원이 됩니다." required maxlength="3000" data-testid="comment-body"></textarea><p class="error" data-form-error role="alert"></p><div class="comment-form-actions"><button type="button" class="btn btn-small" data-do="comment-cancel">취소</button><button class="btn btn-primary btn-small" type="submit">등록</button></div></form>`
      : canReadMember()
        ? '<p class="notice">관리자 운영 권한으로 댓글과 AI 답변을 읽을 수 있어요. 글·댓글·리뷰 작성은 설계사 인증 후 이용해 주세요. <a href="/verify.html">인증 신청·보완하기</a></p>'
        : lockBar(session ? `댓글은 설계사 인증 회원만 볼 수 있어요. (지금: ${statusLabel()})` : "댓글은 설계사 인증 회원만 볼 수 있어요.");
    const ai = d.ai_reply
      ? `<article class="comment-ai" data-testid="ai-reply"><div class="ai-head"><span class="ai-badge">AI</span>AI 참고 답변</div><p class="body-text ai-body clamp" id="ai-body">${E(d.ai_reply.body)}</p><button type="button" class="ai-more" data-do="ai-more" aria-expanded="false" aria-controls="ai-body">더보기</button><p class="source-note">AI가 쓴 참고용 답변이에요. 약관·공식 자료를 꼭 확인하세요.</p></article>`
      : "";
    return `<section class="comments" id="comments"><div class="comments-top"><h2>댓글 <span data-comment-count>${Number(p.comment_count) || 0}</span></h2>${sorter}${form}</div>${canReadMember() ? `<div data-comment-list>${commentListHTML(d)}</div>` : ""}${ai}</section>`;
  }
  // 댓글을 쓰거나 지운 뒤에는 댓글 구역만 다시 그린다(읽던 위치가 튀지 않게).
  async function reloadComments(focusId) {
    const id = current?.post?.id;
    if (page !== "post" || !id || !$("#comments")) return refresh();
    const d = await read("post", { id });
    if (!d.post) return refresh();
    current = d;
    $("#comments").outerHTML = commentsSection(d);
    $$(".post-info .stat-comment, .post-comment-link").forEach((el) => {
      const n = num(d.post.comment_count);
      if (el.classList.contains("stat")) el.innerHTML = `${icon("comment")}<span class="sr-only">댓글</span>${n}`;
      else el.innerHTML = `${icon("comment")} 댓글 ${n}`;
    });
    const mineNow = focusId && $(`#comment-${CSS.escape(focusId)}`);
    if (mineNow) {
      mineNow.classList.add("comment-new");
      mineNow.scrollIntoView({ block: "center" });
    }
  }
  async function write() {
    const denied = isAdmin() ? authorization("admin") : authorization();
    if (denied) return denied;
    const ds = await Promise.all([read("channels"), read("companies")]);
    channels = (ds[0].channels || []).filter((c) => c.enabled !== false);
    companies = (ds[1].companies || []).filter((c) => c.enabled !== false);
    let p = {};
    if (params.get("id")) {
      p = (await read("post", { id: params.get("id") })).post || {};
      if (!p.is_mine) return empty("내 글만 수정할 수 있어요.", "글 목록에서 작성한 글을 확인해 주세요.");
    }
    current = { post: p };
    return `<section class="section"><h1>${p.id ? "글 수정" : "글쓰기"}</h1><p class="notice">회원 글은 개인 의견입니다. 고객의 이름·연락처·계약번호나 타인을 특정할 수 있는 내용을 쓰지 마세요.</p><form data-form="post" id="post-form"><input type="hidden" name="id" value="${E(p.id || "")}"><div class="form-grid">${select(
      "channel_id",
      "채널",
      [["", "채널을 선택하세요"], ...channels.map((c) => [c.id, c.name + (c.anonymous ? " (완전 익명)" : "")])],
      p.channel_id || params.get("channel") || "",
      "required",
    )}${select(
      "content_kind",
      "글 종류 (종류에 따라 손님에게 공개되는 범위가 달라요)",
      Object.entries(kindNames)
        .filter(([k]) => k !== "weekly" || isAdmin())
        .map(([k, label]) => [k, `${label} — ${k === "experience" ? "앞 300자만 누구나 보기" : "본문 전체 누구나 보기"}`]),
      p.content_kind || "experience",
      "required",
    )}${select("company_id", "관련 회사 (선택)", [["", "선택하지 않음"], ...companies.map((c) => [c.id, c.name])], p.company_id || "")}</div><label class="check-line"><input type="checkbox" name="is_question" ${p.is_question ? "checked" : ""}>AI답변 허용하기 <span class="hint">(체크하면 AI 참고 답변이 함께 달릴 수 있어요)</span></label>${
      isAdmin()
        ? `<div class="team-box"><label class="check-line"><input type="checkbox" name="as_team" data-testid="as-team" ${p.as_team || !isVerified() ? "checked" : ""} ${isVerified() ? "" : "required"}>‘보험라이브 운영팀’ 이름으로 쓰기 (작성자 대신 운영팀으로 표시)</label>${p.id ? "" : '<label class="check-line"><input type="checkbox" name="pinned" data-testid="as-notice">공지로 고정 (운영팀 이름일 때만)</label>'}${isVerified() ? "" : '<p class="hint">설계사 인증 전 관리자는 운영팀 이름으로만 쓸 수 있어요.</p>'}</div>`
        : ""
    }<div style="height:20px"></div>${field("title", "제목", "text", p.title || "", 'required minlength="2" maxlength="150" data-testid="post-title"')}${area("body", "본문", p.body || "", 'required minlength="5" maxlength="10000" data-testid="post-body-input"')}<p class="notice anon-note" id="anon-note" hidden>완전 익명 채널이에요. 회사명·닉네임 없이 ‘익명’으로 표시되고, 작성자를 짐작할 수 없도록 관련 회사는 고를 수 없어요.</p><section class="preview-box"><h3>공개 미리보기</h3><p class="small muted" id="public-preview-hint"></p><div class="body-text" id="public-preview"></div></section><label class="check-line"><input type="checkbox" name="checked_preview" required>공개 범위와 미리보기를 확인했습니다.</label>${formEnd(p.id ? "수정 저장" : "글 등록")}</form></section>`;
  }
  async function login() {
    if (session && params.get("returnTo")) {
      location.replace(safeReturn());
      return '<div class="loading" role="status">이전 화면으로 이동합니다.</div>';
    }
    if (session)
      return `<section class="auth-box"><h1>로그인되어 있어요</h1><p>${E(statusLabel())}</p><a class="btn btn-primary" href="/me.html">내 정보로 이동</a><p></p>${btn("로그아웃", "logout")}</section>`;
    return `<section class="auth-box"><a class="back-link" href="/index.html">← 보험라이브 홈</a><h1>로그인</h1><p class="small muted login-first">처음이면 로그인할 때 자동으로 가입돼요. 따로 가입할 필요가 없어요.</p>${loginReasons[params.get("why")] ? `<p class="notice" data-testid="login-reason">${E(loginReasons[params.get("why")])}</p>` : ""}${/KAKAOTALK|NAVER|Instagram|FBAN|FBAV|Line\/|Telegram|; wv\)/i.test(navigator.userAgent) ? '<p class="hint" style="color:#b4235a;margin:10px 0">카카오톡·텔레그램 등 앱 안에서는 Google 로그인이 막힐 수 있어요. 오른쪽 위 메뉴에서 <b>다른 브라우저로 열기</b>(크롬·사파리)를 눌러 주세요. 이메일 로그인은 여기서도 됩니다.</p>' : ""}${btn("Google로 계속하기", "google", `data-testid="google-login" ${window.BL_CONFIG?.googleReady === false ? 'disabled aria-disabled="true"' : ""}`, true)}<p class="hint" style="margin-top:10px">${window.BL_CONFIG?.googleReady === false ? "Google 로그인 연결 준비 중입니다. 아래 이메일로 계속해 주세요." : "Google 계정이 있으면 가장 빠르게 로그인할 수 있어요."}</p><div class="separator">또는 이메일로 로그인</div><form data-form="email" id="email-form">${field("email", "이메일 주소", "email", "", 'required autocomplete="email" placeholder="name@example.com" data-testid="login-email"')}${formEnd("로그인 메일 받기")}</form><div id="otp-area" hidden><form data-form="otp"><h2 style="margin-top:24px">인증번호로 확인</h2><p class="small muted">메일에 인증번호가 있다면 입력해 주세요. 로그인 링크로도 접속할 수 있습니다.</p>${field("token", "이메일 인증번호", "text", "", 'required inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6,10}"')}${formEnd("인증번호 확인")}</form></div><p class="hint" style="margin-top:20px">로그인 메일이 오지 않으면 스팸함을 확인하고, 몇 분 뒤 다시 요청해 주세요.</p><p class="small muted">이용 전 <a class="text-link" href="/terms.html">이용약관</a>과 <a class="text-link" href="/privacy.html">개인정보처리방침</a>을 확인해 주세요. 로그인만으로 회사 인증이 완료되지는 않습니다.</p></section>`;
  }
  async function verify() {
    const denied = authorization("login");
    if (denied) return denied;
    if (isOwner())
      return `<section class="section"><h1>대표 관리자 · 모든 권한</h1><p class="notice success">대표 관리자는 설계사 인증이 면제됩니다. 글·댓글·리뷰와 모든 운영 기능을 이용할 수 있어요.</p><a class="btn btn-primary" href="/admin/">관리자로 이동</a><a class="btn" href="/me.html">내 정보</a></section>`;
    if (viewer?.status === "suspended" || viewer?.status === "withdrawn") return authorization();
    companies = (await read("companies")).companies || [];
    const p = mine?.profile || {};
    return `<section class="section"><h1>설계사 인증 신청</h1><p class="notice">현재 상태: ${E(statusLabel(p))}${p.review_reason ? `<br>운영자 안내: ${E(p.review_reason)}` : ""}</p><p class="muted">현재 소속과 설계사 자격을 확인합니다. 이름·연락처·설계사 고유번호·증빙은 공개되지 않고 담당 운영자만 확인합니다. 증빙 사진은 자동으로 먼저 확인하고, 애매하면 운영자가 직접 확인합니다.</p><form data-form="verification"><div class="form-grid">${field("name", "이름", "text", "", 'required maxlength="60" autocomplete="name" data-testid="verification-name"')}${field("nickname", "닉네임", "text", p.nickname || "", 'required minlength="2" maxlength="20" data-testid="verification-nickname"')}${select("company_id", "현재 소속 회사", companyOptions(), p.company_id || "", 'required data-testid="verification-company"')}${field("company_name", "소속 회사 직접 입력", "text", "", 'maxlength="80" placeholder="회사 이름을 입력해 주세요" data-testid="verification-company-name"').replace('<div class="field">', '<div class="field" data-custom-company hidden>')}${field("phone", "연락처", "tel", "", 'required maxlength="13" inputmode="tel" autocomplete="tel" placeholder="010-0000-0000" data-format="phone" data-testid="verification-phone"')}<div class="field"><div class="label-row"><label for="registration-number">설계사 고유번호</label><button type="button" class="help-tip" data-do="tip" aria-expanded="false" aria-controls="registration-tip" aria-label="설계사 고유번호 확인 방법" data-testid="registration-help">?</button><span class="help-tip-text" id="registration-tip" role="tooltip">e클린보험에서 모집종사자로 본인정보 조회시 설계사 고유번호를 확인할 수 있습니다</span></div><input id="registration-number" name="registration_number" type="text" inputmode="numeric" autocomplete="off" required maxlength="14" placeholder="숫자 14자리" data-format="digits" data-testid="verification-registration"></div><div class="field full"><label for="proof">증빙 사진 1장</label><input id="proof" type="file" name="proof" accept="image/jpeg,image/png,image/webp" required data-testid="verification-proof"><span class="hint proof-guide" data-testid="proof-guide">이클린보험서비스에서 모집종사자 본인정보 조회화면을 프린트 후 첫화면(기본정보)을 jpg등 이미지로 올려주세요</span><span class="hint">JPG·PNG·WebP 파일 1장, 5MB 이하. 제출하지 않은 사진은 자동으로 정리됩니다.</span><img id="proof-preview" class="preview-image" alt="선택한 인증 증빙 미리보기" hidden></div></div><p class="notice">공개 표시: <strong id="display-preview">회사명 · 닉***</strong></p><label class="check-line"><input type="checkbox" name="privacy_consent" required>인증 심사 목적으로 이름·연락처·소속·설계사 고유번호·증빙을 수집하는 데 동의합니다. 증빙과 심사 원본은 처리 후 30일이 지나면 삭제 대상이 됩니다. <a class="text-link" href="/privacy.html" target="_blank" rel="noopener">자세히</a></label>${formEnd("인증 신청 보내기")}</form></section>`;
  }
  async function myPage() {
    const denied = authorization("login");
    if (denied) return denied;
    const d = mine || (await read("me"));
    current = d;
    const p = d.profile || {},
      owner = isOwner();
    const tab = params.get("tab") || "profile",
      tabs = [
        ["profile", "내 정보"],
        ["posts", "내 글"],
        ["comments", "내 댓글"],
        ["bookmarks", "북마크"],
        ["reviews", "내 리뷰"],
      ];
    let body = "";
    if (tab === "posts") body = `<div class="item-list">${feeds(d.posts, { mixed: true })}</div>`;
    else if (tab === "bookmarks") body = `<div class="item-list">${feeds(d.bookmarks, { mixed: true })}</div>`;
    else if (tab === "comments")
      body = d.comments?.length
        ? d.comments
            .map(
              (c) =>
                `<article class="feed-item"><a href="${uri("post.html", { id: c.post_id })}"><p class="body-text">${E(c.body)}</p><span class="muted small">${E(date(c.created_at))} · 원문 보기 →</span></a></article>`,
            )
            .join("")
        : empty("아직 작성한 댓글이 없어요.", "동료의 글에 의견을 남겨 보세요.");
    else if (tab === "reviews")
      body = d.reviews?.length
        ? d.reviews.map((r) => reviewHTML(r)).join("")
        : empty(
            "아직 작성한 리뷰가 없어요.",
            owner ? "회사에 대한 경험을 남길 수 있어요." : "인증된 현재 소속 회사의 리뷰를 남길 수 있어요.",
          );
    else
      body = `<section class="section"><h2>${owner ? "현재 권한" : "현재 인증 상태"}</h2><p class="notice ${isVerified() ? "success" : ""}">${E(statusLabel(p))}${!owner && p.review_reason ? `<br>${E(p.review_reason)}` : ""}</p>${owner ? '<p class="hint">인증 면제 · 모든 운영 기능과 관리자 지정·회수 권한을 사용할 수 있습니다.</p>' : ""}<div class="profile-line"><span>공개 표시</span><span>${E(p.company_name || "소속 미등록")} · ${E((p.nickname || "닉").slice(0, 1))}***</span></div><div class="profile-line"><span>이름</span><span>${E(p.name_masked || "미등록")}</span></div><div class="profile-line"><span>연락처</span><span>${E(p.phone_masked || "미등록")}</span></div><div class="profile-line"><span>${owner ? "설계사 인증" : "인증 유효기간"}</span><span>${owner ? "인증 면제" : E(p.verified_until ? new Date(p.verified_until).toLocaleDateString("ko-KR") : "인증 전")}</span></div><p></p>${owner ? '<a class="btn btn-primary" href="/admin/">관리자 모드</a>' : p.status === "suspended" ? '<a class="btn" href="/help.html">이용 정지 안내</a>' : `<a class="btn btn-primary" href="/verify.html">${isVerified() ? "소속 변경·재인증" : "인증 신청·보완"}</a><p class="hint">소속을 변경하면 재인증 대기로 전환되어 공개 글만 볼 수 있습니다.</p>`}<h2 style="margin-top:32px">닉네임 변경</h2>${isActive() ? `<form data-form="profile">${field("nickname", "새 닉네임", "text", p.nickname || "", 'required minlength="2" maxlength="20"')}${formEnd("닉네임 저장")}</form>` : '<p class="hint">이용 정지 상태에서는 닉네임을 변경할 수 없습니다.</p>'}<div class="divider" style="margin:28px -20px"></div><div class="form-actions">${btn("로그아웃", "logout")}${isAdmin() && !owner ? '<a class="btn" href="/admin/">관리자 모드</a>' : ""}${!owner ? btn("회원 탈퇴", "withdraw") : ""}</div><p class="hint" style="margin-top:16px">${owner ? "대표 관리자는 정지하거나 이 화면에서 권한을 회수할 수 없습니다." : "탈퇴하면 즉시 회원 전용 내용에 접근할 수 없고 남은 글은 ‘탈퇴한 회원’으로 표시됩니다. 삭제할 글은 탈퇴 전에 정리해 주세요."}</p></section>`;
    return `<section class="section"><h1>내 정보</h1><p class="muted">${E(statusLabel(p))}</p></section><nav class="tabs">${tabs.map(([id, label]) => `<a class="${tab === id ? "active" : ""}" href="${uri("me.html", { tab: id })}">${label}</a>`).join("")}</nav>${body}`;
  }
  async function notifications() {
    const denied = authorization("login");
    if (denied) return denied;
    const d = mine || (await read("me"));
    const list = d.notifications || [];
    return `<section class="section"><div class="section-head"><h1>알림</h1>${btn("모두 읽음", "notifications-read", 'class="btn btn-small"')}</div><p class="muted">내 글의 댓글과 인증·운영 처리 결과를 확인해요.</p></section>${list.length ? list.map((n) => `<article class="notification-item ${n.read_at || n.is_read ? "" : "unread"}"><h2>${E(n.title || n.message || n.kind || "새 알림")}</h2>${n.body ? `<p>${E(n.body)}</p>` : ""}<div class="meta"><span>${E(date(n.created_at))}</span>${n.post_id ? `<a data-do="notification-open" data-id="${E(n.id)}" href="${uri("post.html", { id: n.post_id })}">글 보기 →</a>` : ""}${!n.read_at && !n.is_read ? `<button data-do="notification-read" data-id="${E(n.id)}">읽음 표시</button>` : ""}</div></article>`).join("") : empty("새로운 알림이 없어요.", "동료가 내 글에 댓글을 남기면 알려드릴게요.")}`;
  }
  function reviewHTML(r) {
    return `<article class="review" data-testid="review-item"><div class="section-head"><h3>${E(r.title)} ${sampleBadge(r)}</h3>${r.is_mine && isVerified() ? `<div class="form-actions">${btn("수정", "review-edit", `data-id="${E(r.id)}"`)}${btn("삭제", "review-delete", `data-id="${E(r.id)}"`)}</div>` : ""}</div><p class="author">${E(r.author_display)} · ${E(date(r.created_at))}</p><div class="review-scores">${scoreNames.map((s, i) => `<div class="review-score"><span>${s}</span><span class="stars">${"★".repeat(Number(r.scores?.[i]) || 0)}</span></div>`).join("")}</div><p class="body-text" style="margin-top:16px">${E(r.body)}</p>${r.is_truncated ? '<p class="hint">나머지 리뷰는 인증 후 읽을 수 있어요.</p>' : ""}${r.is_mine ? "" : `<button class="text-link small" data-do="report" data-target="review" data-id="${E(r.id)}">리뷰 신고</button>`}</article>`;
  }
  async function company() {
    companies = (await read("companies")).companies || [];
    const id = params.get("id");
    if (!id)
      return `<section class="explore"><h1>보험사·GA 리뷰</h1><p class="muted">현재 소속이 인증된 동료들의 경험을 모읍니다. 5개 이상의 리뷰가 쌓이면 평균 별점을 공개합니다.</p>${["생명보험사", "손해보험사", "GA", "보험사"]
        .map((kind) => [kind, companies.filter((c) => (c.kind || "보험사") === kind)])
        .filter(([, list]) => list.length)
        .map(([kind, list]) => `<h2 class="company-group">${E(kind === "GA" ? "GA(법인보험대리점)" : kind)} <span class="muted small">${list.length}곳</span></h2><div class="channel-cards">${list.map((c) => `<a class="channel-card" href="${uri("company.html", { id: c.id })}"><span class="company-mark">${E(c.name)}</span><div class="channel-card-info"><h2>${E(c.name)}</h2><p>${E(c.kind || "보험사")}</p><span class="small">${c.average != null ? `<span class="stars">★</span> ${Number(c.average).toFixed(1)}` : "리뷰 모으는 중"} · 리뷰 ${Number(c.review_count) || 0}개</span></div></a>`).join("")}</div>`)
        .join("")}${companies.length ? "" : empty("등록된 회사가 없어요.", "운영자가 회사 목록을 준비하고 있습니다.")}</section>`;
    const d = await read("company", { id });
    current = d;
    const c = d.company;
    if (!c) return empty("회사 정보를 찾을 수 없어요.", "보험사·GA 목록에서 다시 선택해 주세요.");
    const canReview = c.enabled !== false && (isOwner() || (isVerified() && mine?.profile?.company_id === id));
    return `<div class="company-cover"></div><section class="company-hero"><a class="back-link" href="/company.html">← 보험사·GA 목록</a><div class="section-head"><h1>${E(c.name)}</h1><span class="company-mark">${E(c.kind || "보험사")}</span></div><p class="muted">${E(c.description || "설계사 동료가 나누는 근무 경험입니다.")}</p><div class="metrics"><div><strong>${Number(c.review_count) || 0}개</strong>리뷰</div><div><strong>${c.average != null ? Number(c.average).toFixed(1) : "모으는 중"}</strong>종합 별점</div><div><strong>5항목</strong>설계사 관점</div><div><strong>1년 1건</strong>회사별 작성</div></div>${c.average != null ? `<div class="rating-grid">${scoreNames.map((s, i) => `<div class="review-score"><span>${s}</span><span>${Number(c.scores?.[i] || 0).toFixed(1)} / 5</span></div>`).join("")}</div>` : '<p class="notice">유효한 리뷰가 5개 이상 모이면 전체·항목별 평균 별점을 공개합니다.</p>'}<p></p>${canReview ? btn("리뷰 작성", "review-new", `data-id="${E(c.id)}" data-testid="review-create"`, true) : isOwner() ? '<p class="hint">숨김 처리된 회사입니다. 관리자에서 회사를 공개한 후 리뷰를 작성할 수 있어요.</p>' : `<p class="hint">현재 소속 회사가 인증된 회원만 리뷰를 작성할 수 있어요.</p>${viewer?.status === "suspended" ? '<a class="btn" href="/help.html">이용 정지 안내</a>' : session ? '<a class="btn" href="/verify.html">내 소속 인증하기</a>' : verifyLink("btn")}`}</section><nav class="company-tabs"><a class="active" href="#company-reviews">리뷰</a><a href="#company-posts">관련 글</a></nav><section id="company-reviews">${d.reviews?.length ? d.reviews.map(reviewHTML).join("") : empty("아직 등록된 리뷰가 없어요.", "현재 소속 회사에 대한 첫 경험을 남겨 주세요.")}</section><section id="company-posts"><h2 class="section">${E(c.name)} 관련 글</h2><div class="item-list">${feeds(d.posts, { mixed: true, compact: true })}</div></section>`;
  }
  // ---- 관리자 화면 (2026-11-09 재구성: 탭별 자료, 목록 → 상세, 한국어 상태, 더 보기) ----
  const adminSections = [
    ["dashboard", "대시보드"],
    ["verifications", "인증 심사"],
    ["members", "회원"],
    ["posts", "글"],
    ["comments", "댓글"],
    ["reviews", "리뷰"],
    ["reports", "신고"],
    ["inquiries", "문의"],
    ["channels", "채널"],
    ["companies", "보험사·GA"],
    ["ai", "AI 답변"],
    ["settings", "금칙어"],
    ["audit", "감사 기록"],
    ["admins", "관리자"],
  ];
  const contentStatusNames = { published: "게시 중", hidden: "숨김", deleted: "삭제됨" };
  const reportStatusNames = { pending: "미처리", maintained: "처리 완료 · 가림 유지", restored: "처리 완료 · 복구" };
  const aiStatusNames = {
    queued: "생성 대기",
    processing: "생성 중",
    review: "검토 대기",
    complete: "공개됨",
    failed: "생성 실패",
    skipped: "반려됨",
  };
  const aiAnswerNames = { review: "검토 대기", published: "공개 중", hidden: "숨김" };
  const aiErrorNames = {
    LEASE_EXPIRED: "처리 시간이 지나 다시 시도합니다",
    GENERATION_FAILED: "답변을 만들지 못했어요",
    subscription_timeout: "답변 생성 시간이 너무 오래 걸렸어요",
    subscription_generation_failed: "답변을 만들지 못했어요",
    subscription_invalid_answer: "답변 형식이 올바르지 않았어요",
    subscription_model_unverified: "정해진 AI 모델로 만들지 못했어요",
    subscription_cli_unavailable: "Mac 처리기에서 AI를 쓸 수 없었어요",
    credential_unavailable: "Mac 처리기 인증 정보를 찾지 못했어요",
  };
  const targetNames = {
    post: "글",
    comment: "댓글",
    review: "리뷰",
    member: "회원",
    channel: "채널",
    company: "회사",
    ai: "AI 답변",
    settings: "설정",
    proof: "증빙",
    notification: "알림",
    verifications: "인증 심사 목록",
    inquiry: "문의",
  };
  const auditNames = {
    admin_read: "인증 심사 목록 열람",
    admin_member_view: "회원 상세 열람",
    admin_verification: "인증 심사",
    auto_verification: "증빙 자동 판정",
    admin_member_status: "회원 상태 변경",
    admin_member_withdraw: "강제 탈퇴",
    admin_report_block: "신고 기능 제한",
    admin_nickname: "닉네임 강제 변경",
    admin_admin_role: "관리자 권한 변경",
    admin_proof_access: "증빙 열람",
    proof_access: "증빙 열람",
    proof_signed_access: "증빙 열람 주소 발급",
    admin_content: "콘텐츠 상태 변경",
    admin_report_resolve: "신고 처리",
    admin_post_move: "글 채널 옮기기",
    admin_reveal_author: "익명 작성자 확인",
    admin_notice_order: "공지 순서 변경",
    admin_channel_save: "채널 저장",
    admin_channel_move: "채널 순서 변경",
    admin_channel_delete: "채널 삭제",
    admin_channel_move_posts: "채널 글 이동",
    admin_company_save: "회사 저장",
    admin_company_delete: "회사 삭제",
    admin_company_merge: "회사 병합",
    admin_ai_settings: "AI 설정",
    admin_ai_publish: "AI 답변 공개",
    admin_ai_reject: "AI 답변 반려",
    admin_ai_edit: "AI 답변 고치기",
    admin_ai_retry: "AI 답변 다시 시도",
    admin_ai_regenerate: "AI 답변 다시 만들기",
    admin_banned_words: "금칙어 저장",
    ai_generated_review: "AI 답변 생성(검토 대기)",
    report: "신고 접수",
    report_temporary_hide: "신고로 임시 가림",
    temporary_expired_restore: "임시 가림 기간 만료 복구",
    appeal: "이의신청",
    profile_submit: "인증 신청",
    withdraw: "탈퇴",
    withdraw_auth_deleted: "탈퇴 계정 삭제 완료",
    proof_cleanup: "증빙 정리",
    suspension_expired: "기간 정지 종료",
    owner_bootstrap: "대표 지정",
    inquiry: "운영팀 문의 접수",
    admin_inquiry_answer: "문의 답변",
  };
  const writeNames = {
    post_save: "글 저장",
    post_delete: "글 삭제",
    comment_save: "댓글 저장",
    comment_delete: "댓글 삭제",
    review_save: "리뷰 저장",
    review_delete: "리뷰 삭제",
    toggle: "좋아요·북마크·팔로우",
    report: "신고",
    appeal: "이의신청",
    notification_read: "알림 읽음",
    profile_update: "내 정보 변경",
    profile_submit: "인증 신청",
    profile_precheck: "인증 신청 입력 확인",
    proof_discard: "실패한 증빙 사진 정리",
    withdraw: "탈퇴",
  };
  const auditName = (a) =>
    auditNames[a] ||
    (String(a).startsWith("admin_write_") ? `관리자 계정의 일반 이용(${writeNames[String(a).slice(12)] || "기타"})` : "기타 처리");
  const auditStatusNames = {
    queued: "다시 만들기 대기",
    edited: "고침",
    saved: "저장",
    up: "위로",
    down: "아래로",
    report_blocked: "신고 제한",
    report_unblocked: "신고 제한 해제",
  };
  const auditStatus = (v) => statusNames[v] || contentStatusNames[v] || auditStatusNames[v] || (/^[a-z_]+$/.test(v) ? "" : v);
  const badge = (text, tone = "") => `<span class="badge ${tone}">${E(text)}</span>`;
  const memberFlags = (m) =>
    [
      m.role === "owner" ? badge("대표", "accent") : m.role === "admin" ? badge("관리자", "accent") : "",
      m.is_test ? badge("시험", "warn") : "",
      m.is_sample ? badge("견본", "warn") : "",
      m.status === "withdrawn" ? badge("탈퇴", "muted") : "",
      m.status === "suspended" ? badge("정지", "danger") : "",
    ].join("");
  const contentFlags = (p) =>
    [
      p.status && p.status !== "published" ? badge(contentStatusNames[p.status] || p.status, "danger") : "",
      p.pinned ? badge("공지", "accent") : "",
      p.as_team ? badge("운영팀 이름", "accent") : "",
      p.anonymous ? badge("익명", "") : "",
      p.is_sample ? badge("견본", "warn") : "",
      p.is_test ? badge("시험", "warn") : "",
    ].join("");
  const providerNames = { google: "Google", email: "이메일" };
  const autoNames = { approve: "자동 승인", reject: "자동 반려", hold: "보류 · 관리자 확인 필요" };
  const autoFieldNames = { match: "일치", mismatch: "다름", unknown: "못 읽음", unclear: "애매" };
  function autoResultHTML(r) {
    if (!r?.decision) return "";
    const f = r.fields || {},
      read = r.read || {};
    return `<div class="auto-result auto-${E(r.decision)}" data-testid="auto-result"><strong>자동 판정: ${E(autoNames[r.decision] || r.decision)}</strong><span>이름 ${E(autoFieldNames[f.name] || "-")}${read.name ? ` (읽은 값 ${E(read.name)})` : ""} · 고유번호 ${E(autoFieldNames[f.number] || "-")}${read.number_last4 ? ` (끝 4자리 ${E(read.number_last4)})` : ""} · 회사 ${E(autoFieldNames[f.company] || "-")}${read.company ? ` (${E(read.company)})` : ""}</span>${r.hold_text ? `<span>${E(r.hold_text)}</span>` : ""}<span class="hint">${E(date(r.at))} · 자동 판정은 아래 심사 결과로 언제든 바꿀 수 있어요.</span></div>`;
  }
  // 관리자 저장 전에 무엇을 바꾸는지 한 번 더 확인한다.
  function adminConfirmText(form) {
    const op = form.elements.operation?.value;
    const chosen = (name) => form.elements[name]?.selectedOptions?.[0]?.textContent?.trim() || "";
    const who = form.dataset.label ? `‘${form.dataset.label}’` : "선택한 대상";
    const lines = {
      verification: `${who} 인증 심사 결과를 ‘${chosen("status")}’(으)로 저장할까요?`,
      member_status: `${who} 회원 상태를 ‘${chosen("status")}’${form.elements.status?.value === "suspended" ? `(${chosen("days")})` : ""}(으)로 바꿀까요?`,
      member_withdraw: `${who} 회원을 강제 탈퇴시킬까요? 개인정보가 바로 지워지고 되돌릴 수 없어요.`,
      report_block: `${who} 회원의 신고 기능을 ‘${chosen("days")}’(으)로 바꿀까요?`,
      nickname: `${who} 닉네임을 ‘${form.elements.nickname?.value || ""}’(으)로 강제로 바꿀까요?`,
      content: `${who}의 표시 상태를 ‘${chosen("status")}’(으)로 바꿀까요?`,
      post_move: `${who} 글을 ‘${chosen("channel_id")}’ 채널로 옮길까요?`,
      report_resolve: `이 신고를 ‘${chosen("decision")}’(으)로 처리할까요?`,
      admin_role: `${chosen("id")} 회원을 ‘${chosen("role")}’ 할까요?`,
      channel_save: `${who} 채널을 저장할까요?`,
      company_save: `${who} 회사를 저장할까요?`,
      channel_delete: `${who} 채널을 삭제할까요? 되돌릴 수 없어요.`,
      company_delete: `${who} 회사를 삭제할까요? 되돌릴 수 없어요.`,
      ai_settings: "AI 답변 설정을 저장할까요?",
      ai_publish: "이 AI 답변을 공개할까요?",
      ai_reject: "이 AI 답변을 반려할까요?",
      ai_edit: "AI 답변 고친 내용을 저장할까요?",
      ai_retry: "이 질문의 AI 답변을 다시 시도할까요?",
      ai_regenerate: "AI 답변을 다시 만들까요? 지금 답변은 새 답변이 나올 때까지 숨겨집니다.",
      reveal_author: "익명 작성자를 확인할까요? 확인한 사실과 사유가 감사 기록에 남습니다.",
      banned_words: "금칙어 목록을 저장할까요?",
      inquiry_answer: "이 답변을 보낼까요? 문의한 회원에게 알림으로 전달됩니다.",
    };
    return lines[op] || "이 내용으로 저장할까요?";
  }
  function adminForm(operation, id, content, label = "저장", extra = "", who = "") {
    return `<form data-form="admin" class="admin-form" data-label="${E(who)}"><input type="hidden" name="operation" value="${E(operation)}"><input type="hidden" name="id" value="${E(id || "")}">${extra}${content}${formEnd(label)}</form>`;
  }
  const reasonField = (value = "", required = true) =>
    field("reason", "처리 사유", "text", value, `${required ? "required minlength=\"2\"" : ""} maxlength="500"`);
  const adminMore = (sec, items) =>
    (items || []).length >= 30
      ? `<p class="more-wrap">${btn("더 보기", "admin-more", `data-section="${E(sec)}" data-testid="admin-more"`)}</p>`
      : "";
  const adminFilterChips = (sec, list, currentValue, extra = {}) =>
    `<nav class="chips admin-filter" aria-label="상태로 보기">${list.map(([s, label]) => `<a class="chip ${currentValue === s ? "active" : ""}" href="${uri("admin/", { section: sec, ...extra, ...(s ? { status: s } : {}) })}">${E(label)}</a>`).join("")}</nav>`;
  const adminSearch = (sec, placeholder, extra = "") =>
    `<form class="search-form admin-search" action="/admin/"><input type="hidden" name="section" value="${E(sec)}">${params.get("status") ? `<input type="hidden" name="status" value="${E(params.get("status"))}">` : ""}${extra}<input name="q" value="${E(params.get("q") || "")}" aria-label="검색" placeholder="${E(placeholder)}"><button class="btn">검색</button></form>`;

  // 채널 영문 주소는 한글 이름에서 자동으로 만든다(예: 영업화법 → yeongeophwabeop).
  function slugify(name, taken = []) {
    const I = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"];
    const V = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"];
    const F = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"];
    let s = "";
    for (const ch of String(name || "")) {
      const c = ch.charCodeAt(0) - 0xac00;
      if (c >= 0 && c < 11172) s += I[Math.floor(c / 588)] + V[Math.floor((c % 588) / 28)] + F[c % 28];
      else if (/[a-z0-9]/i.test(ch)) s += ch.toLowerCase();
      else s += "-";
    }
    s = s.replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, 36) || "ch";
    if (s.length < 2) s += "-ch";
    let out = s,
      n = 2;
    while (taken.includes(out)) out = `${s}-${n++}`;
    return out;
  }

  const revealForm = (target, id) =>
    `<details class="sub-details"><summary>익명 작성자 확인 (감사 기록에 남아요)</summary>${adminForm("reveal_author", id, `${field("reason", "확인 사유", "text", "", 'required minlength="2" maxlength="200" placeholder="예: 신고 처리를 위한 확인"')}`, "작성자 확인", `<input type="hidden" name="target" value="${target}">`)}</details>`;
  function channelFormHTML(c = {}) {
    return adminForm(
      "channel_save",
      c.id,
      `${field("name", "채널 이름", "text", c.name || "", 'required minlength="2" maxlength="40" data-testid="channel-name"')}${area("description", "설명", c.description || "", 'required maxlength="500"')}${c.slug ? `<p class="hint">영문 주소: ${E(c.slug)} (자동으로 정해져요)</p><input type="hidden" name="slug" value="${E(c.slug)}">` : '<p class="hint">영문 주소는 이름에서 자동으로 만들어져요.</p>'}<input type="hidden" name="display_order" value="${E(c.display_order ?? Math.max(0, ...channels.map((x) => Number(x.display_order) || 0)) + 10)}"><label class="check-line"><input type="checkbox" name="enabled" ${c.enabled !== false ? "checked" : ""}>채널 사용(끄면 회원에게 보이지 않아요)</label><label class="check-line"><input type="checkbox" name="anonymous" data-testid="channel-anonymous" ${c.anonymous ? "checked" : ""}>완전 익명 채널(회사명·닉네임 없이 ‘익명’으로 표시)</label><p class="hint">완전 익명을 켜면 이 채널의 글·댓글이 익명으로 바뀌고, 나중에 꺼도 이미 익명인 글은 익명으로 남아요.</p>`,
      c.id ? "수정 저장" : "채널 추가",
      "",
      c.name || "새",
    );
  }
  function companyFormHTML(c = {}) {
    return adminForm(
      "company_save",
      c.id,
      `${field("name", "회사 이름", "text", c.name || "", 'required minlength="2" maxlength="80"')}${select("kind", "회사 종류", companyKinds.map((k) => [k, k]), c.kind || "", 'required')}${area("description", "회사 설명", c.description || "", 'maxlength="1000"')}<label class="check-line"><input type="checkbox" name="enabled" ${c.enabled !== false ? "checked" : ""}>회사 사용(끄면 목록에서 숨겨져요)</label>`,
      c.id ? "수정 저장" : "회사 추가",
      "",
      c.name || "새",
    );
  }
  const companyKinds = ["생명보험사", "손해보험사", "GA", "보험사"];
  function removalFormHTML(kind, item, items) {
    const isChannel = kind === "channel",
      label = isChannel ? "채널" : "회사",
      count = Number(isChannel ? item.post_count : item.reference_count) || 0;
    const targets = items.filter((x) => x.id !== item.id && x.enabled !== false);
    const detail = isChannel
      ? `연결된 글 ${count}개`
      : `관련 글 ${Number(item.post_count) || 0}개 · 리뷰 ${Number(item.total_review_count) || 0}개 · 회원 ${Number(item.member_count) || 0}명`;
    if (count > 0 && !targets.length)
      return `<p class="notice">${detail}. 먼저 다른 사용 중인 ${label}를 추가해 주세요. 자료를 옮길 곳이 있어야 삭제할 수 있어요.</p>`;
    const target =
      count > 0
        ? select(
            isChannel ? "target_channel_id" : "target_company_id",
            isChannel ? "글을 옮길 채널" : "합칠 회사",
            [["", "선택하세요"], ...targets.map((x) => [x.id, x.name])],
            "",
            "required",
          )
        : "";
    return adminForm(
      isChannel ? "channel_delete" : "company_delete",
      item.id,
      `<p class="notice">${E(count > 0 ? `${detail}. 고른 ${label}로 자료를 모두 옮긴 뒤 이 ${label}를 삭제합니다.` : `연결된 자료가 없어 바로 삭제할 수 있어요.`)} 삭제 내역은 감사 기록에 남습니다.</p>${target}${reasonField()}<label class="check-line"><input type="checkbox" name="confirm_delete" required>‘${E(item.name)}’ ${label} 삭제 내용을 확인했습니다.</label>`,
      count > 0 ? (isChannel ? "글 옮기고 채널 삭제" : "자료 합치고 회사 삭제") : `${label} 삭제`,
      "",
      item.name,
    );
  }

  // 목록 한 줄씩 그리는 함수(더 보기에서도 같이 씀)
  const adminRows = {
    verifications: (v) =>
      `<article class="admin-card" data-testid="verification-item"><h3>${E(v.company_name)} · ${E(v.nickname)} ${memberFlags(v)}</h3><p class="small">상태: ${E(statusNames[v.status] || v.status)} · 신청 ${E(date(v.submitted_at))}</p><p>이름: ${E(v.name || "-")}<br>연락처: ${E(v.phone || "-")}<br>설계사 고유번호: ${E(v.registration_number || "미입력")}</p>${autoResultHTML(v.auto_result)}<div class="form-actions">${v.proof_path ? btn("증빙 사진 보기 (60초)", "proof", `data-id="${E(v.id)}" data-testid="proof-view"`) : '<span class="muted small">보관 중인 증빙이 없어요.</span>'}<a class="btn" href="${uri("admin/", { section: "members", id: v.id })}">회원 상세</a></div>${v.review_reason ? `<p class="notice small">현재 안내: ${E(v.review_reason)}</p>` : ""}${adminForm(
        "verification",
        v.id,
        `${select(
          "status",
          "심사 결과",
          [
            ["", "선택하세요"],
            ["verified", "승인 — 인증 완료"],
            ["supplement", "보완 요청"],
            ["rejected", "반려"],
          ],
          "",
          "required",
        )}${
          v.company_id
            ? ""
            : `${select("company_id", "연결할 소속 회사 (승인할 때 필수)", [["", "선택하세요"], ...(current?.admin?.companies || []).map((c) => [c.id, c.name])], "")}<p class="hint">신청자가 직접 입력한 회사: ${E(v.company_name)}. 목록에 없으면 보험사·GA 관리에서 먼저 추가해 주세요.</p>`
        }${reasonField("", false)}<p class="hint">보완 요청·반려는 사유가 필요해요. 사유는 신청자에게 알림으로 전해집니다.</p>`,
        "심사 결과 저장",
        "",
        `${v.company_name} · ${v.nickname}`,
      )}</article>`,
    members: (m) =>
      `<a class="admin-row" href="${uri("admin/", { section: "members", id: m.id })}" data-testid="member-row"><span class="row-main"><strong>${E(m.nickname || "(닉네임 없음)")}</strong> ${memberFlags(m)}</span><span class="row-sub">${E(m.company_name || "소속 미등록")} · ${E(m.role === "owner" ? "대표 관리자" : statusNames[m.status] || m.status)}${m.status === "verified" && m.verified_until ? ` · 인증 만료 ${E(new Date(m.verified_until).toLocaleDateString("ko-KR"))}` : ""}${m.suspended_until ? ` · 정지 끝 ${E(date(m.suspended_until))}` : ""} · 가입 ${E(date(m.created_at))}</span></a>`,
    posts: (p) =>
      `<details class="admin-row" data-testid="admin-post"><summary><span class="row-main"><strong>${E(p.title)}</strong> ${contentFlags(p)}</span><span class="row-sub">${E(p.channel_name || "")} · ${E(p.author_display || "")} · ${E(date(p.created_at))} · 좋아요 ${Number(p.likes) || 0} · 댓글 ${Number(p.comment_count) || 0}</span></summary><div class="row-detail"><p class="body-text">${E(String(p.body || "").slice(0, 600))}${String(p.body || "").length > 600 ? "…" : ""}</p><p><a class="text-link" href="${uri("post.html", { id: p.id })}" target="_blank" rel="noopener">글 화면에서 보기 →</a></p>${
        p.pinned && p.status !== "deleted"
          ? `<div class="form-actions"><span class="small muted">공지 순서</span>${btn("위로", "admin-order", `data-op="notice_order" data-dir="up" data-id="${E(p.id)}"`)}${btn("아래로", "admin-order", `data-op="notice_order" data-dir="down" data-id="${E(p.id)}"`)}</div>`
          : ""
      }${p.anonymous ? revealForm("post", p.id) : ""}${adminForm(
        "content",
        p.id,
        `${select(
          "status",
          "표시 상태",
          [
            ["", "선택하세요"],
            ["published", "게시"],
            ["hidden", "숨김"],
            ["deleted", "삭제"],
          ],
          "",
          "required",
        )}<label class="check-line"><input type="checkbox" name="pinned" ${p.pinned ? "checked" : ""}>공지로 고정</label>${reasonField()}`,
        "상태 저장",
        '<input type="hidden" name="target" value="post">',
        p.title,
      )}${adminForm(
        "post_move",
        p.id,
        `${select("channel_id", "다른 채널로 옮기기", [["", "선택하세요"], ...(current?.admin?.channels || []).filter((c) => c.id !== p.channel_id).map((c) => [c.id, c.name + (c.enabled === false ? " (숨김)" : "")])], "", "required")}${reasonField()}`,
        "채널 옮기기",
        "",
        p.title,
      )}</div></details>`,
    comments: (c) =>
      `<details class="admin-row" data-testid="admin-comment"><summary><span class="row-main"><strong>${E(String(c.body || "").slice(0, 60))}</strong> ${contentFlags(c)}</span><span class="row-sub">글: ${E(c.post_title || "")} · ${E(c.author_display || "")} · ${E(date(c.created_at))}</span></summary><div class="row-detail"><p class="body-text">${E(c.body)}</p><p><a class="text-link" href="${uri("post.html", { id: c.post_id })}" target="_blank" rel="noopener">글 화면에서 보기 →</a></p>${c.anonymous ? revealForm("comment", c.id) : ""}${adminForm(
        "content",
        c.id,
        `${select("status", "표시 상태", [["", "선택하세요"], ["published", "게시"], ["hidden", "숨김"], ["deleted", "삭제"]], "", "required")}${reasonField()}`,
        "상태 저장",
        '<input type="hidden" name="target" value="comment">',
        String(c.body || "").slice(0, 20),
      )}</div></details>`,
    reviews: (r) =>
      `<details class="admin-row" data-testid="admin-review"><summary><span class="row-main"><strong>${E(r.title)}</strong> ${contentFlags(r)}</span><span class="row-sub">${E(r.company_name || "")} · ${E(r.author_display || "")} · ${E(date(r.created_at))}</span></summary><div class="row-detail"><p class="body-text">${E(r.body)}</p>${adminForm(
        "content",
        r.id,
        `${select("status", "표시 상태", [["", "선택하세요"], ["published", "게시"], ["hidden", "숨김"], ["deleted", "삭제"]], "", "required")}${reasonField()}`,
        "상태 저장",
        '<input type="hidden" name="target" value="review">',
        r.title,
      )}</div></details>`,
    reports: (r) => {
      const t = r.target_info || {},
        rep = r.reporter || {},
        done = r.status !== "pending";
      return `<details class="admin-row" data-testid="report-item" ${done ? "" : "open"}><summary><span class="row-main"><strong>${E(targetNames[r.target] || "콘텐츠")} 신고 · ${E(t.title || String(t.body || "").slice(0, 40) || "삭제된 대상")}</strong> ${badge(reportStatusNames[r.status] || r.status, done ? "muted" : "danger")}${Number(r.same_target_pending) > 1 ? badge(`같은 대상 신고 ${Number(r.same_target_pending)}건`, "warn") : ""}</span><span class="row-sub">신고자 ${E(rep.nickname || "-")}(${E(rep.company_name || "소속 미등록")}) · 지금까지 신고 ${Number(rep.total) || 0}회 · 복구로 끝난 신고 ${Number(rep.restored) || 0}회${rep.blocked_until && Date.parse(rep.blocked_until) > Date.now() ? " · 신고 제한 중" : ""} · ${E(date(r.created_at))}</span></summary><div class="row-detail"><p class="body-text"><b>신고 사유</b><br>${E(r.reason)}</p><div class="notice small"><b>대상 내용</b> (${E(contentStatusNames[t.status] || "확인 불가")} · ${E(t.author_display || "")})<br>${E(String(t.body || "").slice(0, 300))}${t.post_id ? `<br><a class="text-link" href="${uri("post.html", { id: t.post_id })}" target="_blank" rel="noopener">글 화면에서 보기 →</a>` : ""}</div>${
        done
          ? `<p class="small">처리 결과: ${E(reportStatusNames[r.status] || r.status)} · ${E(r.decision_reason || "")}${r.decided_by_name ? ` · 처리자 ${E(r.decided_by_name)}` : ""} · ${E(date(r.decided_at))}</p>`
          : `${t.pinned ? '<p class="hint">운영 공지라 신고로 자동 가려지지 않았어요.</p>' : ""}${adminForm(
              "report_resolve",
              r.id,
              `${select("decision", "처리 결정", [["", "선택하세요"], ["restore", "문제없음 — 게시 유지·복구"], ["maintain", "위반 확인 — 가림"]], "", "required")}${reasonField()}`,
              "신고 처리 완료",
            )}`
      }<details class="sub-details"><summary>신고자 신고 기능 제한</summary>${adminForm(
        "report_block",
        rep.id,
        `${select("days", "제한 기간", [["", "선택하세요"], ["7", "7일"], ["30", "30일"], ["90", "90일"], ["36500", "무기한"], ["0", "제한 풀기"]], "", "required")}${reasonField()}`,
        "신고 제한 저장",
        "",
        rep.nickname || "신고자",
      )}</details></div></details>`;
    },
    ai: (j) =>
      `<details class="admin-row" data-testid="ai-item"><summary><span class="row-main"><strong>${E(j.post_title || "질문 글")}</strong> ${badge(aiStatusNames[j.status] || j.status, j.status === "failed" ? "danger" : j.status === "review" ? "warn" : "muted")}${j.answer_status ? badge(`답변 ${aiAnswerNames[j.answer_status] || j.answer_status}`, "") : ""}</span><span class="row-sub">${E(date(j.created_at))}${j.attempts ? ` · 시도 ${Number(j.attempts)}회` : ""}${j.error_code ? ` · ${E(aiErrorNames[j.error_code] || "처리 중 문제가 있었어요")}` : ""}</span></summary><div class="row-detail"><p><a class="text-link" href="${uri("post.html", { id: j.post_id })}" target="_blank" rel="noopener">질문 글 보기 →</a></p>${
        j.answer
          ? `${adminForm("ai_edit", j.id, area("body", "AI 답변 (고쳐서 저장할 수 있어요)", j.answer, 'required minlength="20" maxlength="15000"'), "고친 내용 저장")}<div class="form-actions">${adminForm("ai_publish", j.id, "", "검토 후 공개")}${adminForm("ai_reject", j.id, "", "답변 반려")}${adminForm("ai_regenerate", j.id, "", "다시 만들기")}</div>`
          : '<p class="muted small">아직 만들어진 답변이 없어요.</p>'
      }${["failed", "skipped"].includes(j.status) ? adminForm("ai_retry", j.id, "", "다시 시도") : ""}</div></details>`,
    inquiries: (q) =>
      `<details class="admin-row" data-testid="inquiry-item" ${q.status === "open" ? "open" : ""}><summary><span class="row-main"><strong>${E({ general: "일반 문의", privacy: "개인정보 요청", rights: "권리침해 신고", account: "계정 문의" }[q.kind] || "문의")} · ${E(String(q.body || "").slice(0, 40))}</strong> ${badge(q.status === "open" ? "답변 전" : "답변 완료", q.status === "open" ? "danger" : "muted")}${q.member?.is_test ? badge("시험", "warn") : ""}</span><span class="row-sub">${E(q.member?.nickname || "-")}(${E(q.member?.company_name || "소속 미등록")}) · ${E(date(q.created_at))}</span></summary><div class="row-detail"><p class="body-text">${E(q.body)}</p>${q.link ? `<p class="small">관련 주소: ${E(q.link)}</p>` : ""}<p><a class="text-link" href="${uri("admin/", { section: "members", id: q.member?.id })}">문의한 회원 상세 →</a></p>${q.status === "answered" ? `<div class="notice small"><b>보낸 답변</b>${q.answered_by_name ? ` · ${E(q.answered_by_name)}` : ""} · ${E(date(q.answered_at))}<br>${E(q.answer)}</div>` : adminForm("inquiry_answer", q.id, area("answer", "답변 (회원에게 알림으로 전달)", "", 'required minlength="2" maxlength="2000"'), "답변 보내기")}</div></details>`,
    audit: (a) =>
      `<div class="admin-row static" data-testid="audit-row"><span class="row-main"><strong>${E(a.actor_name || (a.detail?.by === "자동 판정" ? "자동 판정" : "시스템"))}</strong> · ${E(auditName(a.action))}${a.target ? ` · ${E(targetNames[a.target] || a.target)}` : ""}</span><span class="row-sub">${E(date(a.created_at))}${a.detail?.reason ? ` · 사유: ${E(a.detail.reason)}` : ""}${a.detail?.decision ? ` · ${E(autoNames[a.detail.decision] || a.detail.decision)}` : ""}${a.detail?.status && !a.detail?.decision && auditStatus(a.detail.status) ? ` · ${E(auditStatus(a.detail.status))}` : ""} · 기록 ${E(a.id)}</span></div>`,
  };

  const adminRender = {
    dashboard(d) {
      const k = d.dashboard || {},
        t = d.todo || {};
      const todoTotal = (Number(t.verifications) || 0) + (Number(t.reports) || 0) + (Number(t.ai_review) || 0) + (Number(t.inquiries) || 0);
      const labels = [
        ["members", "가입 회원"],
        ["verified", "인증 완료"],
        ["pending", "인증 대기"],
        ["today_posts", "오늘 글"],
        ["today_comments", "오늘 댓글"],
        ["expiring", "30일 안에 인증 만료"],
      ];
      const trend = d.trend || [];
      const peak = Math.max(1, ...trend.flatMap((x) => [Number(x.members) || 0, Number(x.posts) || 0, Number(x.comments) || 0]));
      const bar = (n, cls) => `<i class="${cls}" style="height:${Math.round(((Number(n) || 0) / peak) * 100)}%" title="${Number(n) || 0}"></i>`;
      return `<section class="admin-todo ${todoTotal ? "has-todo" : ""}" data-testid="admin-todo"><h3>처리할 일 ${todoTotal}건</h3>${todoTotal ? `<div class="todo-links"><a href="/admin/?section=verifications&amp;status=pending">인증 심사 대기 ${Number(t.verifications) || 0}건${t.verifications_hold ? ` (자동 판정 보류 ${Number(t.verifications_hold)}건)` : ""}</a><a href="/admin/?section=reports">미처리 신고 ${Number(t.reports) || 0}건</a><a href="/admin/?section=ai">AI 답변 검토 ${Number(t.ai_review) || 0}건</a><a href="/admin/?section=inquiries">답변 전 문의 ${Number(t.inquiries) || 0}건</a></div>` : '<p class="muted small">지금 처리할 일이 없어요.</p>'}</section><div class="status-list">${labels.map(([key, label]) => `<div><strong>${Number(k[key]) || 0}</strong><small>${label}</small></div>`).join("")}</div><p class="notice small" data-testid="dashboard-count-basis">집계 기준: 시험 계정·임시 견본은 빼고 셉니다. ${Number(k.expiring) ? `<a href="/admin/?section=members&amp;status=expiring">인증 만료 예정자 보기 →</a>` : ""}</p><section class="trend" aria-label="최근 14일 추이"><h3>최근 14일 가입·글·댓글</h3><div class="trend-legend"><span class="tm">가입</span><span class="tp">글</span><span class="tc">댓글</span></div><div class="trend-bars">${trend.map((x) => `<div class="trend-day" title="${E(x.day)} 가입 ${Number(x.members) || 0} · 글 ${Number(x.posts) || 0} · 댓글 ${Number(x.comments) || 0}"><div class="trend-stack">${bar(x.members, "tm")}${bar(x.posts, "tp")}${bar(x.comments, "tc")}</div><small>${E(String(x.day).slice(3))}</small></div>`).join("")}</div></section>`;
    },
    verifications(d) {
      const c = d.counts || {};
      return `${adminFilterChips("verifications", [["pending", `대기 ${Number(c.pending) || 0}`], ["supplement", `보완 요청 ${Number(c.supplement) || 0}`], ["rejected", `반려 ${Number(c.rejected) || 0}`], ["verified", `승인 ${Number(c.verified) || 0}`], ["all", "전체"]], d.status)}<div class="admin-list" data-admin-list="verifications">${(d.items || []).map(adminRows.verifications).join("") || empty("이 상태의 인증 신청이 없어요.", "위에서 다른 상태를 골라 보세요.")}</div>${adminMore("verifications", d.items)}`;
    },
    members(d) {
      return `${adminSearch("members", "이름·이메일·닉네임·설계사 고유번호로 검색")}${adminFilterChips("members", [["", "전체"], ["verified", "인증 완료"], ["pending", "인증 대기"], ["unverified", "인증 전·반려·만료"], ["expiring", "만료 예정"], ["suspended", "정지"], ["withdrawn", "탈퇴"], ["admin", "관리자"], ["test", "시험"], ["sample", "견본"]], d.status, params.get("q") ? { q: params.get("q") } : {})}<div class="admin-list" data-admin-list="members">${(d.items || []).map(adminRows.members).join("") || empty("조건에 맞는 회원이 없어요.", "검색어나 상태를 바꿔 보세요.")}</div>${adminMore("members", d.items)}`;
    },
    member(d) {
      const m = d.member || {};
      const line = (label, value) => `<div class="profile-line"><span>${label}</span><span>${value}</span></div>`;
      const reg = m.registration_number || (m.has_registration ? "심사 후 30일이 지나 원본 삭제됨(중복 확인용 값만 보관)" : "미등록");
      const editable = m.role !== "owner" && m.status !== "withdrawn";
      const ownerOnly = m.role === "admin" && !isOwner();
      return `<p><a class="back-link" href="/admin/?section=members">← 회원 목록</a></p><article class="admin-card member-detail" data-testid="member-detail"><h3>${E(m.nickname || "(닉네임 없음)")} ${memberFlags(m)}</h3>${line("이름", E(m.name || "미등록 또는 정리됨"))}${line("닉네임", E(m.nickname || "-"))}${line("연락처", E(m.phone || "미등록 또는 정리됨"))}${line("설계사 고유번호", E(reg))}${line("소속 회사", E(m.company_name || "소속 미등록"))}${line("이메일", E(m.email || (m.auth_deleted ? "로그인 계정 삭제됨" : "-")))}${line("로그인 방식", E((m.providers || [m.provider]).filter(Boolean).map((x) => providerNames[x] || x).join(", ") || "-"))}${line("가입일", E(date(m.signed_up_at || m.created_at)))}${line("마지막 로그인", E(date(m.last_sign_in_at) || "-"))}${line("인증 상태", E(m.role === "owner" ? "대표 관리자 · 인증 면제" : m.status === "verified" && !validVerification(m) ? "인증 기간 만료 · 재인증 필요" : statusNames[m.status] || m.status))}${line("인증 만료일", E(m.verified_until ? new Date(m.verified_until).toLocaleDateString("ko-KR") : "-"))}${m.suspended_until ? line("정지 끝나는 때", E(date(m.suspended_until))) : ""}${m.report_blocked_until ? line("신고 제한", `${E(Date.parse(m.report_blocked_until) > Date.now() ? `${date(m.report_blocked_until)}까지` : "끝남")} · ${E(m.report_block_reason || "")}`) : ""}${line("쓴 글·댓글·리뷰", `글 ${Number(m.post_count) || 0} · 댓글 ${Number(m.comment_count) || 0} · 리뷰 ${Number(m.review_count) || 0}`)}${line("신고 이력", `한 신고 ${Number(m.reports_made) || 0}건(복구로 끝남 ${Number(m.reports_made_restored) || 0}) · 받은 신고 ${Number(m.reports_received) || 0}건`)}${m.review_reason ? `<p class="notice small">현재 안내: ${E(m.review_reason)}</p>` : ""}${autoResultHTML(m.auto_result)}<div class="form-actions">${m.has_proof ? btn("증빙 사진 보기 (60초)", "proof", `data-id="${E(m.id)}" data-testid="proof-view"`) : '<span class="muted small">보관 중인 증빙이 없어요.</span>'}${m.status === "pending" || m.status === "supplement" ? `<a class="btn" href="/admin/?section=verifications&amp;status=${E(m.status)}">인증 심사로</a>` : ""}</div>${
        (m.report_history || []).length
          ? `<details class="sub-details"><summary>신고 이력 ${m.report_history.length}건 보기</summary>${m.report_history.map((h) => `<p class="small">${h.kind === "made" ? "한 신고" : "받은 신고"} · ${E(targetNames[h.target] || h.target)} · ${E(reportStatusNames[h.status] || h.status)} · ${E(date(h.created_at))}<br>${E(h.reason)}</p>`).join("")}</details>`
          : ""
      }</article>${
        !editable
          ? `<p class="notice">${m.role === "owner" ? "대표 관리자는 정지·탈퇴시키거나 권한을 낮출 수 없어요." : "탈퇴한 회원이라 바꿀 수 있는 내용이 없어요."}</p>`
          : ownerOnly
            ? '<p class="notice">관리자 계정의 상태 변경·강제 탈퇴는 대표만 할 수 있어요.</p>'
            : `<section class="admin-card"><h3>회원 상태 바꾸기</h3>${adminForm(
                "member_status",
                m.id,
                `${select("status", "변경할 상태", [["", "선택하세요"], ["suspended", "이용 정지"], ["unverified", "정지 해제 — 재인증 필요"], ["verified", "정지 해제 — 기존 인증 유지"]], "", "required")}${select("days", "정지 기간 (이용 정지일 때)", [["7", "7일"], ["1", "1일"], ["3", "3일"], ["30", "30일"], ["90", "90일"], ["365", "1년"], ["0", "기간 없이(직접 풀 때까지)"]], "7")}${reasonField()}`,
                "회원 상태 저장",
                "",
                m.nickname,
              )}</section><section class="admin-card"><h3>닉네임 강제 변경</h3>${adminForm("nickname", m.id, `${field("nickname", "새 닉네임", "text", m.nickname || "", 'required minlength="2" maxlength="20"')}${reasonField()}`, "닉네임 변경", "", m.nickname)}</section><section class="admin-card"><h3>신고 기능 제한</h3><p class="hint">악의적으로 신고를 반복하는 회원의 신고를 막습니다.</p>${adminForm("report_block", m.id, `${select("days", "제한 기간", [["", "선택하세요"], ["7", "7일"], ["30", "30일"], ["90", "90일"], ["36500", "무기한"], ["0", "제한 풀기"]], "", "required")}${reasonField()}`, "신고 제한 저장", "", m.nickname)}</section><section class="admin-card danger-zone"><h3>강제 탈퇴</h3><p class="hint">개인정보와 증빙이 바로 지워지고 되돌릴 수 없어요. 남은 글은 ‘탈퇴한 회원’으로 표시됩니다.</p>${adminForm("member_withdraw", m.id, `${reasonField()}<label class="check-line"><input type="checkbox" name="confirm_withdraw" required>‘${E(m.nickname || "이 회원")}’ 회원을 강제 탈퇴시키는 것을 확인했습니다.</label>`, "강제 탈퇴", "", m.nickname)}</section>`
      }`;
    },
    posts(d) {
      const chOpts = [["", "모든 채널"], ...(d.channels || []).map((c) => [c.id, c.name])];
      return `${adminSearch("posts", "제목·본문 검색", d.channel_id ? `<input type="hidden" name="channel_id" value="${E(d.channel_id)}">` : "")}${adminFilterChips("posts", [["", "전체"], ["published", "게시 중"], ["hidden", "숨김"], ["deleted", "삭제됨"], ["notice", "공지(순서 바꾸기)"]], d.status, { ...(params.get("q") ? { q: params.get("q") } : {}), ...(d.channel_id ? { channel_id: d.channel_id } : {}) })}<form class="search-form admin-search" action="/admin/"><input type="hidden" name="section" value="posts">${d.status ? `<input type="hidden" name="status" value="${E(d.status)}">` : ""}${select("channel_id", "채널로 보기", chOpts, d.channel_id || "")}<button class="btn">보기</button></form><p class="hint">글을 누르면 내용·상태 바꾸기·채널 옮기기가 열려요. 운영팀 이름의 글·공지는 <a class="text-link" href="/write.html">글쓰기</a>에서 ‘보험라이브 운영팀 이름으로 쓰기’를 고르세요.</p><div class="admin-list" data-admin-list="posts">${(d.items || []).map(adminRows.posts).join("") || empty("조건에 맞는 글이 없어요.", "검색어나 상태를 바꿔 보세요.")}</div>${adminMore("posts", d.items)}`;
    },
    comments(d) {
      return `${adminSearch("comments", "댓글 내용 검색")}${adminFilterChips("comments", [["", "전체"], ["published", "게시 중"], ["hidden", "숨김"], ["deleted", "삭제됨"]], d.status, params.get("q") ? { q: params.get("q") } : {})}<div class="admin-list" data-admin-list="comments">${(d.items || []).map(adminRows.comments).join("") || empty("조건에 맞는 댓글이 없어요.", "검색어나 상태를 바꿔 보세요.")}</div>${adminMore("comments", d.items)}`;
    },
    reviews(d) {
      return `${adminSearch("reviews", "리뷰 제목·내용 검색")}${adminFilterChips("reviews", [["", "전체"], ["published", "게시 중"], ["hidden", "숨김"], ["deleted", "삭제됨"]], d.status, params.get("q") ? { q: params.get("q") } : {})}<div class="admin-list" data-admin-list="reviews">${(d.items || []).map(adminRows.reviews).join("") || empty("조건에 맞는 리뷰가 없어요.", "검색어나 상태를 바꿔 보세요.")}</div>${adminMore("reviews", d.items)}`;
    },
    reports(d) {
      return `${adminFilterChips("reports", [["pending", "미처리만"], ["done", "처리 완료"], ["all", "전체"]], d.status)}<p class="hint">같은 대상에 서로 다른 회원 신고가 3건 이상 모이면 자동으로 임시 가려집니다. 처리하면 같은 대상의 미처리 신고가 함께 정리돼요.</p><div class="admin-list" data-admin-list="reports">${(d.items || []).map(adminRows.reports).join("") || empty(d.status === "pending" ? "미처리 신고가 없어요." : "신고가 없어요.", "신고가 들어오면 이곳과 알림으로 알려 드려요.")}</div>${adminMore("reports", d.items)}`;
    },
    inquiries(d) {
      return `${adminFilterChips("inquiries", [["open", "답변 전"], ["answered", "답변 완료"], ["all", "전체"]], d.status)}<p class="hint">개인정보 열람·정정·삭제 요청은 확인 후 회원 화면이나 관리 기능으로 처리하고 답변해 주세요.</p><div class="admin-list" data-admin-list="inquiries">${(d.items || []).map(adminRows.inquiries).join("") || empty("문의가 없어요.", "회원이 도움말 화면에서 문의하면 이곳과 알림으로 알려 드려요.")}</div>${adminMore("inquiries", d.items)}`;
    },
    channels(d) {
      const list = d.channels || [];
      return `<p>${btn("+ 채널 추가", "admin-dialog", 'data-kind="channel" data-mode="add" data-testid="channel-add"', true)}</p><div class="admin-list">${list.map((c, i) => `<div class="admin-row static manage-row" data-testid="channel-row"><span class="row-main">${channelDisc(c)}<strong>${E(c.name)}</strong> ${c.enabled !== false ? badge("사용 중", "ok") : badge("숨김", "muted")}</span><span class="row-sub">글 ${Number(c.post_count) || 0}개 · 팔로워 ${Number(c.followers) || 0}명 · ${E(String(c.description || "").slice(0, 60))}</span><span class="row-actions">${btn("▲", "admin-order", `data-op="channel_move" data-dir="up" data-id="${E(c.id)}" aria-label="${E(c.name)} 위로" ${i === 0 ? "disabled" : ""}`)}${btn("▼", "admin-order", `data-op="channel_move" data-dir="down" data-id="${E(c.id)}" aria-label="${E(c.name)} 아래로" ${i === list.length - 1 ? "disabled" : ""}`)}${btn("수정", "admin-dialog", `data-kind="channel" data-mode="edit" data-id="${E(c.id)}" data-testid="channel-edit"`)}${btn("삭제", "admin-dialog", `data-kind="channel" data-mode="delete" data-id="${E(c.id)}" data-danger="1" data-testid="channel-delete"`)}</span></div>`).join("") || empty("채널이 없어요.", "위의 ‘채널 추가’를 눌러 만들어 주세요.")}</div>`;
    },
    companies(d) {
      const list = d.companies || [];
      return `<p>${btn("+ 보험사·GA 추가", "admin-dialog", 'data-kind="company" data-mode="add" data-testid="company-add"', true)}</p>${adminSearch("companies", "회사 이름 찾기")}<div class="admin-list">${list
        .filter((c) => !params.get("q") || c.name.includes(params.get("q")))
        .map((c) => `<div class="admin-row static manage-row" data-testid="company-row"><span class="row-main"><strong>${E(c.name)}</strong> ${badge(c.kind || "보험사", "")} ${c.enabled !== false ? badge("사용 중", "ok") : badge("숨김", "muted")}</span><span class="row-sub">리뷰 ${Number(c.total_review_count) || 0} · 관련 글 ${Number(c.post_count) || 0} · 소속 회원 ${Number(c.member_count) || 0}</span><span class="row-actions">${btn("수정", "admin-dialog", `data-kind="company" data-mode="edit" data-id="${E(c.id)}"`)}${btn("삭제", "admin-dialog", `data-kind="company" data-mode="delete" data-id="${E(c.id)}" data-danger="1"`)}</span></div>`)
        .join("") || empty("회사가 없어요.", "위의 ‘보험사·GA 추가’를 눌러 주세요.")}</div>`;
    },
    ai(d) {
      const s = d.settings || {};
      return `<article class="admin-card"><h3>AI 참고 답변 설정</h3><p class="muted small">질문 글만 처리합니다. AI 답변은 관리자가 검토해 공개해야 보이며, 사람 댓글·인기 수치에 포함되지 않아요.</p>${adminForm("ai_settings", "", `<label class="check-line"><input type="checkbox" name="enabled" ${s.ai_enabled ? "checked" : ""}>AI 답변 만들기 사용</label><p></p>${field("daily_limit", "하루 최대 생성 수", "number", s.ai_daily_limit || 30, 'required min="1" max="30"')}`, "AI 설정 저장")}</article><h3>생성 기록</h3><div class="admin-list" data-admin-list="ai">${(d.items || []).map(adminRows.ai).join("") || empty("생성 기록이 없어요.", "AI가 켜진 상태에서 질문 글이 올라오면 이곳에 표시돼요.")}</div>${adminMore("ai", d.items)}`;
    },
    settings(d) {
      const words = d.settings?.banned_words || [];
      return `<article class="admin-card"><h3>금칙어</h3><p class="hint">글·댓글·리뷰에 이 단어가 들어 있으면 올리지 못하고 안내가 나와요. 쉼표나 줄바꿈으로 구분합니다(최대 300개, 단어당 30자).</p>${adminForm("banned_words", "", area("words", "금칙어 목록", words.join(", "), 'maxlength="9000" data-testid="banned-words"'), "금칙어 저장")}</article>`;
    },
    audit(d) {
      const hide = params.get("reads") !== "show";
      return `<p class="notice small">감사 기록은 고치거나 지울 수 없어요. 처리자·행동·대상·사유를 확인할 수 있습니다.</p>${adminSearch("audit", "처리자·행동·대상·사유 검색", hide ? "" : '<input type="hidden" name="reads" value="show">')}<p class="small"><a class="text-link" href="${uri("admin/", { section: "audit", ...(params.get("q") ? { q: params.get("q") } : {}), ...(hide ? { reads: "show" } : {}) })}">${hide ? "열람 기록도 보기" : "열람 기록 숨기기"}</a></p><div class="admin-list" data-admin-list="audit">${(d.items || []).map(adminRows.audit).join("") || empty("기록이 없어요.", "검색어를 바꿔 보세요.")}</div>${adminMore("audit", d.items)}`;
    },
    admins(d) {
      return `<p class="notice small">관리자 지정·회수는 대표만 할 수 있어요. 권한은 서버에서 확인합니다.</p><div class="admin-list">${(d.admins || []).map((a) => `<div class="admin-row static"><span class="row-main"><strong>${E(a.nickname || "닉네임 미등록")}</strong> ${a.role === "owner" ? badge("대표", "accent") : badge("관리자", "accent")} ${a.is_test ? badge("시험", "warn") : ""}</span><span class="row-sub">${E(a.company_name || "소속 미등록")} · ${E(a.role === "owner" ? "대표 관리자 · 모든 권한" : statusNames[a.status] || a.status)}</span></div>`).join("")}</div>${
        isOwner()
          ? `<article class="admin-card"><h3>관리자 지정·회수</h3>${adminForm(
              "admin_role",
              "",
              `${select("id", "대상 회원 (탈퇴·정지 회원 제외)", [["", "선택하세요"], ...(d.candidates || []).map((m) => [m.id, `${m.nickname} · ${m.company_name || "소속 미등록"} (${statusNames[m.status] || m.status}${m.role === "admin" ? " · 관리자" : ""}${m.is_test ? " · 시험" : ""})`])], "", "required")}${select("role", "권한", [["", "선택하세요"], ["admin", "관리자로 지정"], ["member", "관리자 권한 회수"]], "", "required")}${reasonField()}`,
              "권한 변경",
            )}</article>`
          : ""
      }`;
    },
  };

  async function admin() {
    const denied = authorization("admin");
    if (denied) return denied;
    const section = adminSections.some(([s]) => s === params.get("section")) ? params.get("section") : "dashboard";
    const sec = section === "members" && params.get("id") ? "member" : section;
    const args = { v: "2", section: sec, q: params.get("q") || "", status: params.get("status") || "", limit: 30 };
    if (params.get("id")) args.id = params.get("id");
    if (params.get("channel_id")) args.channel_id = params.get("channel_id");
    if (sec === "audit" && params.get("reads") !== "show") args.hide_reads = "true";
    const d = await read("admin", args);
    current = { admin: d, args, offset: (d.items || []).length };
    if (d.channels) channels = d.channels;
    if (d.companies) companies = d.companies;
    const t = d.todo || {};
    const tabCount = { verifications: Number(t.verifications) || 0, reports: Number(t.reports) || 0, ai: Number(t.ai_review) || 0, inquiries: Number(t.inquiries) || 0 };
    return `<section class="section admin-page"><div class="section-head"><h1>관리자 모드</h1><span class="status-badge">${isOwner() ? "대표 관리자 · 모든 권한" : "관리자"}</span></div><nav class="admin-tabs" aria-label="관리 메뉴">${adminSections.map(([id, label]) => `<a class="chip ${section === id ? "active" : ""}" href="${uri("admin/", { section: id })}">${label}${tabCount[id] ? ` <span class="tab-count">${tabCount[id]}</span>` : ""}</a>`).join("")}</nav><h2>${E(adminSections.find(([s]) => s === section)?.[1] || "대시보드")}</h2>${adminRender[sec](d)}</section>`;
  }
  const policyDocs = {
    terms: `<h1>이용약관</h1><p class="document-meta">시행일: 2026년 11월 7일 · 보험라이브</p><h2>1. 서비스와 가입</h2><p>보험라이브는 보험설계사들이 실무 지식과 개인 경험을 나누는 커뮤니티입니다. 성인 이용자는 Google 또는 이메일로 로그인할 수 있습니다. 설계사 인증을 마쳐야 회원 전용 글·댓글·AI 답변을 읽고 글을 작성할 수 있습니다. 가입 정보와 증빙은 본인의 현재 정보여야 합니다.</p><h2>2. 공개 범위</h2><p>공개 화면에는 소속 회사명과 닉네임 첫 글자 뒤 별표 3개만 표시합니다. 완전익명 채널의 글·댓글은 회사명·닉네임 없이 ‘익명’으로만 표시하며, 운영자는 신고 처리 등 필요한 경우에만 사유를 기록하고 작성자를 확인합니다. 실무지식·커리어·운영팀 정리는 본문 전체, 경험·자유 글과 회사 리뷰는 앞부분 최대 300자를 공개합니다. 댓글·대댓글·AI 답변은 인증 회원에게만 제공됩니다. 본문 자체에 개인정보를 쓰면 작성자를 추정할 수 있으므로 게시 전에 확인해 주세요.</p><h2>3. 회원 콘텐츠와 책임</h2><p>게시물의 권리는 작성자에게 있습니다. 작성자는 서비스 안에서 콘텐츠를 저장·표시하고 신고를 처리하는 데 필요한 이용을 허락합니다. 회원의 글과 리뷰는 개인 의견이며 소속 회사나 운영팀의 공식 입장, 보험상품 가입 권유 또는 개별 계약에 대한 확정적인 판단이 아닙니다. 실제 계약·보장·지급 여부는 약관과 공식 자료로 확인해야 합니다.</p><h2>4. 금지 행위와 운영 조치</h2><p>허위사실·명예훼손·개인정보 공개·욕설·사칭·불법 자료·도배·무단 광고·계정 거래·악의적 신고·권한 우회는 금지합니다. 운영자는 사유를 기록하고 글 숨김·삭제, 인증 보완·반려, 일시 또는 지속적 이용 제한을 적용할 수 있습니다. 주요 결과는 서비스 내 알림과 내 정보에 안내합니다.</p><h2>5. 권리침해 신고와 임시조치</h2><p>사생활 침해·명예훼손 등 권리침해를 주장하는 회원은 글·댓글·리뷰의 신고 메뉴에서 대상과 침해 사실을 구체적으로 소명해 삭제 또는 조치를 요청할 수 있습니다. 신고는 설계사 인증을 마친 회원이 할 수 있으며 본인의 글은 신고할 수 없습니다. 같은 콘텐츠에 서로 다른 회원의 신고가 3건 이상 모이거나 운영자가 필요하다고 판단하면 접근을 임시 차단하고 신청인·게시자에게 서비스 내 알림으로 알리며 원래 게시물 위치에 조치 사실을 표시합니다. 운영 공지는 신고로 자동 가려지지 않고 운영자가 직접 검토합니다. 권리침해 판단이 어렵거나 다툼이 예상될 때 정보통신망법 제44조의2에 따른 임시조치는 30일 이내로 합니다. 운영자는 그 안에 소명을 검토해 복구 또는 위반에 따른 최종 가림·삭제를 결정합니다. 미결인 임시조치는 기간 종료 후 복구하고 당사자에게 알립니다. 조치 사유가 잘못되었다고 판단하면 해당 신고에 추가 소명을 적어 이의를 제기할 수 있습니다.</p><h2>6. 회사 리뷰와 AI</h2><p>회사 리뷰는 현재 소속이 인증된 회원이 회사별 365일에 1건 작성할 수 있으며 본인의 리뷰를 수정할 수 있습니다. 5개 이상의 유효 리뷰가 모이면 평균을 공개합니다. AI 참고 답변은 AI 작성 표시를 하며 정확성을 보장하지 않습니다. 사람 댓글과 인기 수치에 포함하지 않고 운영 검토와 설정에 따라 표시합니다.</p><h2>7. 탈퇴와 변경</h2><p>내 정보에서 탈퇴하면 회원 전용 접근을 즉시 차단하고 남은 콘텐츠의 작성자를 ‘탈퇴한 회원’으로 표시합니다. 삭제를 원하는 본인 글·댓글은 탈퇴 전에 삭제해 주세요. 관계 법령상 보관 의무가 없는 인증 정보는 삭제합니다. 약관 변경과 중요한 운영 변경은 공지로 안내합니다.</p>`,
    privacy: `<h1>개인정보처리방침</h1><p class="document-meta">시행일: 2026년 11월 7일 · 최종 수정: 2026년 11월 9일(정식 공개 전 보완) · 보험라이브</p><h2>1. 처리하는 개인정보와 목적</h2><ul class="policy-list"><li><b>로그인·회원 관리</b>: 이메일 주소, 로그인 방식(Google 또는 이메일)과 로그인 제공자가 발급하는 계정 식별정보, 가입·마지막 로그인 시각 — 회원 확인, 부정 이용 방지</li><li><b>설계사 인증</b>: 이름, 닉네임, 현재 소속 회사, 연락처, 설계사 고유번호, 증빙 사진 1장 — 설계사·소속 확인, 같은 고유번호의 중복 가입 확인</li><li><b>서비스 이용</b>: 글·댓글·리뷰, 좋아요·북마크·팔로우, 신고·이의신청·운영팀 문의 내용, 알림 — 커뮤니티 제공, 신고·분쟁 처리, 문의 답변</li><li><b>운영 기록</b>: 관리자 처리 내역(처리자·행동·대상·사유), 증빙 열람 기록 — 운영 책임 확인, 위변조 방지</li></ul><p>주민등록번호는 수집하지 않습니다. 증빙에 주민등록번호·주소·고객정보가 보이면 올리기 전에 가려 주세요.</p><h2>2. 공개 정보와 접근 권한</h2><p>공개 화면에 회사명과 닉네임 첫 글자·별표 3개만 표시합니다(완전익명 채널은 ‘익명’으로만 표시하고, 운영자의 작성자 확인은 사유와 함께 감사 기록에 남깁니다). 실명, 연락처, 설계사 고유번호, 증빙 사진은 공개하지 않습니다. 증빙은 비공개 저장소에 보관하고 담당 관리자만 60초 동안 유효한 서명 주소로 확인합니다. 제출한 증빙 사진은 운영팀 Mac의 기기 안 글자인식(Apple Vision)으로 이름·설계사 고유번호·소속 회사를 읽어 신청 내용과 자동으로 비교하며, 사진과 읽은 내용을 외부 AI나 다른 서비스로 보내지 않습니다. 자동 판정 결과(승인·반려·보류)는 운영자가 확인하고 바꿀 수 있습니다. 관리자의 열람과 처리 행동은 감사 기록으로 남깁니다. 공개 회원 명부나 회원별 공개 프로필을 제공하지 않습니다.</p><h2>3. 보유 기간과 파기</h2><p>계정과 닉네임·현재 소속·인증 상태는 회원 유지 기간 동안 보관합니다. 인증 증빙 사진과 심사용 이름·연락처·설계사 고유번호 원본은 승인·반려 등 처리 후 30일이 지나면 파일과 원본을 지웁니다. 같은 고유번호의 중복 가입을 막기 위해 원래 번호 대신 변환한 확인값만 탈퇴 전까지 보관합니다. 신청하지 않고 남은 사진은 24시간 안에, 신청이 실패한 사진은 곧바로 정리합니다. 탈퇴하면 접근을 즉시 막고 이름·연락처·고유번호·확인값·증빙·알림·운영팀 문의를 지우며, 남은 글·댓글은 신원과의 공개 연결을 끊고 ‘탈퇴한 회원’으로 표시합니다. 운영 처리 기록은 위변조 방지를 위해 지우지 않고 보관합니다. 법적 보존 의무가 생긴 정보는 법령이 정한 범위와 기간에 한해 따로 보관합니다.</p><h2>4. 처리 위탁과 국외 이전</h2><p>서비스 제공을 위해 아래 사업자의 서비스를 이용하며, 이 과정에서 개인정보가 국외에서 처리될 수 있습니다. 정보는 서비스를 이용할 때 암호화된 통신(HTTPS)으로 전송되며, 회원 탈퇴 또는 위탁 종료 시까지 보관되고 각 사업자의 정책에 따라 파기됩니다.</p><ul class="policy-list"><li><b>Supabase</b> — 회원 계정·로그인, 데이터베이스, 증빙 사진 등 파일 저장 — 위 1의 정보 — 데이터 저장 위치: 유럽(프랑스) 지역(서비스 설정 기준)</li><li><b>Google</b> — Google 로그인을 선택한 경우 계정 확인 — 이메일 주소, 계정 식별정보 — 미국 등 해외(사업자 정책에 따름)</li><li><b>Resend</b> — 이메일 로그인 메일 발송 — 이메일 주소 — 미국 등 해외(사업자 정책에 따름)</li><li><b>GitHub(GitHub Pages)</b> — 웹 화면 제공 — 접속 과정의 기술 정보(IP 주소 등)가 사업자 정책에 따라 처리될 수 있음 — 미국 등 해외</li><li><b>Anthropic(Claude)</b> — 질문 글을 선택한 경우 AI 참고 답변 생성 — 질문 글의 제목·본문(작성자의 이름·연락처·닉네임 등 알려진 개인정보는 지우고 전달) — 미국 등 해외(사업자 정책에 따름)</li></ul><p>국외 처리를 원하지 않으면 가입하지 않거나 탈퇴할 수 있으며, 이 경우 서비스를 이용할 수 없습니다. 광고 추적, 외부 광고 이미지, 제3자 분석 스크립트는 넣지 않습니다.</p><h2>5. 이용자의 권리와 행사 방법</h2><p>내 정보에서 현재 상태, 내 글·댓글·북마크·알림을 확인하고 닉네임을 바꾸거나 탈퇴할 수 있습니다. 개인정보 열람·정정·삭제·처리정지 요청은 로그인 후 <a class="text-link" href="/help.html#inquiry">이용 도움말의 ‘운영팀 문의’</a>에서 ‘개인정보 열람·정정·삭제 요청’을 골라 보내 주세요. 운영팀이 확인해 알림으로 답변합니다. 개인정보가 담긴 글·댓글은 해당 콘텐츠의 신고 버튼으로도 알릴 수 있습니다.</p><h2>6. 개인정보 보호책임자와 문의</h2><p>개인정보 보호책임자: 보험라이브 운영팀. 개인정보 관련 문의·불만·피해 구제 요청은 로그인 후 <a class="text-link" href="/help.html#inquiry">운영팀 문의</a>로 접수합니다.</p><h2>7. 안전성 확보 조치와 로그인 유지</h2><p>데이터베이스에서 회원 상태와 역할을 검사해 공개·회원·관리자 정보를 분리하고, 전송 구간은 HTTPS를 사용합니다. 관리자 처리와 증빙 열람은 감사 기록으로 남깁니다. 로그인 유지를 위해 브라우저 저장소에 로그인 정보를 보관합니다. 공용 기기에서는 사용 후 오른쪽 위 ‘로그아웃’을 눌러 주세요.</p><h2>8. AI 참고 답변</h2><p>질문형 글을 선택한 경우 게시물의 제목과 본문을 운영팀 Mac 처리기에서 Anthropic의 Claude(기존 구독)로 처리해 참고 답변을 만들 수 있습니다. 회원의 실명·연락처·증빙은 답변 생성에 넣지 않으며, 만들어진 답변은 운영자가 검토한 뒤 공개합니다. 질문에도 고객 개인정보나 민감한 계약자료를 적지 마세요.</p><h2>9. 방침 변경</h2><p>이 방침을 바꾸면 서비스 공지로 알립니다.</p>`,
    rules: `<h1>커뮤니티 운영정책</h1><p class="document-meta">시행일: 2026년 11월 7일</p><h2>경험은 솔직하게, 사람은 존중해 주세요</h2><p>직접 겪은 사실과 의견을 구분하고 자료의 기준일을 함께 적어 주세요. 타인·회사에 대한 허위사실, 명예훼손, 위협, 혐오와 비방은 허용하지 않습니다. 리뷰와 회원 글은 작성자 개인 의견입니다.</p><h2>영업화법은 정직하게</h2><p>허위·과장·부당권유 화법, 고객정보·녹취 게시는 금지합니다.</p><h2>개인정보와 고객자료를 올리지 마세요</h2><p>본인이나 타인의 실명·연락처·주소·주민등록번호·계약번호·질병정보·고객 사진, 개인을 추정할 수 있는 조합 정보를 공개하지 마세요. 회사 이름은 실제 명칭으로 표시하지만 지점·직급·담당 고객 등 개인을 특정하는 상세정보는 게시하지 않습니다.</p><h2>반복 게시와 영업을 제한합니다</h2><p>인증 회원은 글 하루 10개, 글 사이 60초, 댓글 하루 50개, 댓글 사이 10초 간격을 지켜야 합니다. 서버에서 제한을 적용합니다. 같은 내용 반복, 무단 광고·모집·판매, 계정 거래, 자동화 도배, 악의적 신고는 제재 대상입니다. 신고도 회원당 하루 10건으로 제한합니다.</p><h2>신고 → 운영자 판단(필요하면 임시 가림)</h2><p>설계사 인증 회원은 각 글·댓글·리뷰에서 신고 사유를 선택하고 대상과 침해 사실을 구체적으로 적어 신고할 수 있습니다(내 글은 신고할 수 없음). 같은 콘텐츠에 서로 다른 회원의 신고가 3건 이상 모이면 운영자 판단 전까지 임시로 가리고 신고자와 작성자에게 알립니다. 운영 공지는 신고로 자동 가려지지 않습니다. 운영자는 사실관계·소명을 확인해 복구하거나 위반이 확인된 경우 가림을 유지·삭제합니다. 권리침해 다툼을 위한 임시조치는 최대 30일이며 미결 건은 기간 종료 후 복구합니다. 신고 자체가 위반 확정을 뜻하지 않습니다.</p><h2>처리 결과와 이의신청</h2><p>콘텐츠 숨김·삭제, 인증 보완·반려, 일시 정지 또는 반복 위반 계정 정지를 적용할 수 있습니다. 사유는 내 정보와 알림에 표시합니다. 이의가 있으면 해당 대상의 신고 메뉴에서 ‘처리 결과 이의신청’을 선택하고 기존 조치와 추가 소명을 적어 주세요. 운영자는 검토 사유와 결과를 기록합니다.</p><h2>AI와 회사 리뷰</h2><p>AI 참고 답변은 사람의 답변과 구분하여 표시하며 전문적인 확정 판단으로 사용하지 마세요. 현재 인증된 회사의 리뷰만 작성할 수 있고, 실제 근무 경험 없이 평가하거나 리뷰를 거래·조작하는 행위를 금지합니다.</p>`,
    help: `<h1>이용 도움말</h1><h2>이용하는 순서</h2><ol><li>Google 또는 이메일로 로그인합니다.</li><li>설계사 인증에서 이름·소속·연락처·설계사 고유번호와 증빙 사진 1장을 제출합니다.</li><li>내 정보와 알림에서 심사 결과를 확인합니다.</li><li>인증 후 글·댓글·좋아요·리뷰를 이용합니다(팔로우·북마크는 로그인만 하면 돼요).</li></ol><h2>공개 표시</h2><p>예를 들어 닉네임 ‘바른설계’이고 소속이 삼성생명이면 ‘삼성생명 · 바***’로 보입니다. ‘완전익명’ 채널에서는 회사명·닉네임 없이 ‘익명’으로 보여요. 소속 변경 시 재인증을 신청해야 합니다.</p><h2>신고와 이의신청</h2><p>문제가 있는 글·댓글·리뷰는 그 화면의 <b>‘신고’</b> 버튼을 눌러 주세요(설계사 인증 회원). 운영자가 검토해 알림으로 결과를 알려 드리며, 같은 콘텐츠에 서로 다른 회원의 신고가 3건 이상 모이면 검토 전까지 임시로 가립니다. 내 글이 가려졌다면 그 글 화면의 <b>‘내 글 조치에 이의신청’</b> 버튼으로 소명할 수 있어요.</p><h2 id="inquiry">운영팀 문의</h2><p>개인정보 열람·정정·삭제 요청, 권리침해 신고, 계정 문의와 그 밖의 문의를 보낼 수 있어요. 답변은 알림으로 드립니다.</p><!--inquiry--><h2>로그인 메일이 오지 않아요</h2><p>스팸함과 이메일 주소를 확인하고 몇 분 뒤 다시 요청해 주세요. Google 계정이 있으면 Google로 로그인할 수 있어요.</p><h2>계정을 정리하고 싶어요</h2><p>내 정보에서 본인이 쓴 글·댓글을 확인하고 삭제한 뒤 탈퇴할 수 있습니다. 탈퇴 즉시 회원 전용 내용에 접근할 수 없고, 남겨둔 글은 ‘탈퇴한 회원’으로 보입니다.</p>`,
  };
  function inquiryForm() {
    if (!session)
      return `<p class="notice">문의는 로그인한 뒤 보낼 수 있어요. <a class="text-link" href="${E(loginUrl("/help.html#inquiry"))}">로그인하기</a></p>`;
    return `<form data-form="inquiry" class="inquiry-form">${select("kind", "문의 종류", [["", "선택하세요"], ["general", "일반 문의"], ["privacy", "개인정보 열람·정정·삭제 요청"], ["rights", "권리침해 신고"], ["account", "계정 문의"]], "", 'required data-testid="inquiry-kind"')}${field("link", "관련 글 주소 (선택)", "text", "", 'maxlength="300" placeholder="글 화면 주소를 붙여 넣어 주세요"')}${area("body", "문의 내용", "", 'required minlength="5" maxlength="2000" data-testid="inquiry-body" placeholder="주민등록번호 등 필요 없는 개인정보는 적지 마세요."')}${formEnd("문의 보내기")}</form>`;
  }
  function dialog(html) {
    $("#dialog-content").innerHTML = html;
    $("#dialog").showModal();
  }
  function closeDialog() {
    if ($("#dialog").open) $("#dialog").close();
    $("#dialog-content").innerHTML = "";
  }
  function confirmation(action, id, title, body) {
    dialog(
      `<h2>${E(title)}</h2><p>${E(body)}</p><form data-form="confirm"><input type="hidden" name="action" value="${E(action)}"><input type="hidden" name="id" value="${E(id || "")}"><p class="error" data-form-error role="alert"></p><div class="modal-actions">${btn("취소", "dialog-close")}<button type="submit" class="btn btn-danger">${E(title)}</button></div></form>`,
    );
  }
  function reportDialog(target, id, appeal = false) {
    dialog(
      `<h2>${appeal ? "이의신청" : "신고하기"}</h2><p class="small muted">${appeal ? "가려진 내 글에 대한 처리 결과에 의견을 남겨 주세요. 운영자가 검토해 알림으로 알려 드려요." : "운영자가 검토한 뒤 결과를 알려 드려요. 같은 콘텐츠에 서로 다른 회원의 신고가 3건 이상 모이면 운영자 판단 전까지 임시로 가려집니다. 의견이 다르다는 이유만으로 신고하지 마세요."}</p><form data-form="report"><input type="hidden" name="appeal" value="${appeal ? "true" : "false"}"><input type="hidden" name="target" value="${E(target)}"><input type="hidden" name="id" value="${E(id)}">${select(
        "reason_type",
        "신고 사유",
        [
          ["privacy", "개인정보 노출"],
          ["defamation", "명예훼손·허위사실"],
          ["spam", "광고·도배"],
          ["abuse", "욕설·혐오·괴롭힘"],
          ["appeal", "처리 결과 이의신청"],
          ["other", "기타 권리침해"],
        ],
        appeal ? "appeal" : "privacy",
      )}${area("reason_detail", "침해 사실과 요청 사항", "", 'required minlength="5" maxlength="2000" data-testid="report-reason" placeholder="어떤 내용으로 어떤 권리가 침해되었는지 적어 주세요. 필요한 소명과 요청하는 조치를 함께 알려 주세요."')}<label class="check-line"><input type="checkbox" required>사실에 근거한 신고이며 악의적 신고가 아님을 확인합니다.</label>${formEnd("신고 접수")}<p></p>${btn("취소", "dialog-close")}</form>`,
    );
  }
  function reviewDialog(r = {}, companyId) {
    dialog(
      `<h2>${r.id ? "리뷰 수정" : "회사 리뷰 작성"}</h2><p class="hint">${isOwner() ? "대표 관리자는 인증·소속 제한 없이 회사별 365일에 1건 작성할 수 있습니다." : "현재 소속 회사만 365일에 1건 작성할 수 있습니다."} 지점명·실명·고객정보를 쓰지 마세요.</p><form data-form="review"><input type="hidden" name="id" value="${E(r.id || "")}"><input type="hidden" name="company_id" value="${E(r.company_id || companyId || "")}">${field("title", "리뷰 제목", "text", r.title || "", 'required minlength="2" maxlength="150"')}<div class="review-scores">${scoreNames
        .map((s, i) =>
          select(
            "score_" + i,
            s,
            [
              [1, "1점"],
              [2, "2점"],
              [3, "3점"],
              [4, "4점"],
              [5, "5점"],
            ],
            r.scores?.[i] || 3,
            "required",
          ),
        )
        .join(
          "",
        )}</div>${area("body", "근무 경험과 의견", r.body || "", 'required minlength="10" maxlength="5000"')}<p class="notice small">리뷰 앞부분 최대 300자는 누구나 볼 수 있습니다. 평균 별점은 유효 리뷰 5개부터 공개됩니다.</p>${formEnd("리뷰 저장")}<p></p>${btn("취소", "dialog-close")}</form>`,
    );
  }
  function updatePreview() {
    const form = $("#post-form");
    if (form) {
      const kind = form.elements.content_kind.value,
        body = form.elements.body.value;
      const anon = !!channels.find((c) => c.id === form.elements.channel_id.value)?.anonymous || !!current?.post?.anonymous;
      $("#anon-note").hidden = !anon;
      form.elements.company_id.disabled = anon;
      if (anon) form.elements.company_id.value = "";
      const partial = kind === "experience";
      $("#public-preview").textContent = partial ? Array.from(body).slice(0, 300).join("") : body;
      $("#public-preview-hint").textContent = partial
        ? Array.from(body).length <= 300
          ? "이 글은 짧아 본문 전체가 공개됩니다."
          : "본문 처음부터 300자까지 공개되고 나머지는 인증 회원에게만 보입니다."
        : "본문 전체가 공개됩니다. 모든 댓글과 AI 답변은 인증 회원만 읽을 수 있습니다.";
    }
  }
  // 입력하는 대로 000-0000-0000 모양으로(서울 02, 지역번호, 대표번호도 자연스럽게)
  function formatPhone(value) {
    const d = String(value).replace(/\D/g, "").slice(0, 11);
    if (d.startsWith("02")) {
      if (d.length <= 2) return d;
      if (d.length <= 5) return `${d.slice(0, 2)}-${d.slice(2)}`;
      if (d.length <= 9) return `${d.slice(0, 2)}-${d.slice(2, 5)}-${d.slice(5)}`;
      return `${d.slice(0, 2)}-${d.slice(2, 6)}-${d.slice(6)}`;
    }
    if (/^1[5-9]/.test(d)) return d.length <= 4 ? d : `${d.slice(0, 4)}-${d.slice(4, 8)}`;
    if (d.length <= 3) return d;
    if (d.startsWith("010")) return d.length <= 7 ? `${d.slice(0, 3)}-${d.slice(3)}` : `${d.slice(0, 3)}-${d.slice(3, 7)}-${d.slice(7)}`;
    if (d.length <= 6) return `${d.slice(0, 3)}-${d.slice(3)}`;
    if (d.length <= 10) return `${d.slice(0, 3)}-${d.slice(3, 6)}-${d.slice(6)}`;
    return `${d.slice(0, 3)}-${d.slice(3, 7)}-${d.slice(7)}`;
  }
  function proofUploadError(error) {
    const msg = String(error?.message || error?.error || "");
    if (/row-level security|security policy|Unauthorized|403|5장|최대/i.test(msg))
      return new Error("증빙 사진 보관 한도(5장)를 넘었어요. 제출하지 않은 사진은 자동으로 정리되니 잠시 뒤 다시 시도해 주세요.");
    if (/too large|413|size/i.test(msg)) return new Error("사진 용량이 너무 커요. 5MB 이하로 올려 주세요.");
    if (/mime|type/i.test(msg)) return new Error("JPG·PNG·WebP 사진만 올릴 수 있어요.");
    return error;
  }
  function updateDisplay() {
    const form = $('form[data-form="verification"]');
    if (!form) return;
    const opt = form.elements.company_id.selectedOptions[0];
    const name =
      form.elements.company_id.value === "custom"
        ? form.elements.company_name.value
        : opt?.value
          ? opt.textContent
          : "회사명";
    const nick = Array.from(form.elements.nickname.value || "닉")[0];
    $("#display-preview").textContent = `${name || "회사명"} · ${nick}***`;
    const custom = form.elements.company_id.value === "custom";
    form.elements.company_name.required = custom;
    $("[data-custom-company]", form).hidden = !custom;
  }
  function safeReturn(value = params.get("returnTo")) {
    try {
      if (!value || !String(value).startsWith("/")) return "/me.html";
      const target = new URL(value, location.origin);
      if (target.origin !== location.origin || /^\/(join|login|auth)(\.html)?$/.test(target.pathname)) return "/me.html";
      return target.pathname + target.search + target.hash;
    } catch {
      return "/me.html";
    }
  }
  // 구글·메일 링크로 다녀와도 원래 화면으로 돌아가도록 기기에 잠시 기억한다.
  function rememberReturn() {
    const target = safeReturn();
    try {
      localStorage.setItem("bl_return_to", target);
    } catch {}
    return target;
  }
  function afterLoginTarget() {
    let stored = null;
    try {
      stored = localStorage.getItem("bl_return_to");
      localStorage.removeItem("bl_return_to");
    } catch {}
    return safeReturn(params.get("returnTo") || stored);
  }
  function verifyLink(cls = "btn btn-primary") {
    return session
      ? `<a class="${cls}" href="/verify.html">설계사 인증하기</a>`
      : `<a class="${cls}" href="${E(loginUrl("/verify.html"))}">로그인하고 인증하기</a>`;
  }
  const displayName = () => viewer?.nickname || session?.user?.email?.split("@")[0] || "회원";
  // 통신이 실패해도 이 기기의 로그인 기록은 반드시 지운다.
  function clearLocalSession() {
    try {
      Object.keys(localStorage)
        .filter((k) => /^sb-.+-auth-token/.test(k))
        .forEach((k) => localStorage.removeItem(k));
    } catch {}
    session = null;
    viewer = null;
    mine = null;
  }
  async function logout(message = "로그아웃했어요.") {
    let failed = false;
    try {
      const { error } = await sb.auth.signOut({ scope: "local" });
      failed = !!error;
    } catch {
      failed = true;
    }
    clearLocalSession();
    closeDialog();
    try {
      sessionStorage.setItem(
        "bl_flash",
        failed ? "인터넷 연결이 불안정해 서버에는 알리지 못했지만, 이 기기에서는 로그아웃했어요." : message,
      );
    } catch {}
    // 화면 상태를 완전히 비우기 위해 새로 연다. 로그인이 필요한 화면이면 홈으로 간다.
    if (["me", "notifications", "write", "verify", "admin", "login", "auth"].includes(page)) location.replace("/index.html");
    else location.reload();
  }
  let accountChecked = false;
  async function refresh() {
    const stamp = ++renderId;
    current = null;
    $("#content").innerHTML = '<div class="loading" role="status">화면을 불러오는 중입니다.</div>';
    try {
      const r = await sb.auth.getSession();
      session = r.data.session;
      viewer = null;
      mine = null;
      if (session && !accountChecked) {
        const { data, error } = await sb.auth.getUser();
        if (!error && data?.user) accountChecked = true;
        else if (error && [401, 403, 404].includes(error.status)) {
          // 서버에서 지워졌거나 만료된 계정의 기록이 기기에 남은 경우
          await sb.auth.signOut({ scope: "local" }).catch(() => {});
          clearLocalSession();
          notify("로그인이 만료되었어요. 다시 로그인해 주세요.");
        }
      }
      if (session) {
        mine = await read("me");
        if (viewer?.status === "withdrawn") {
          await sb.auth.signOut({ scope: "local" }).catch(() => {});
          clearLocalSession();
        }
      }
      let html;
      if (policyDocs[page]) html = `<article class="section policy">${policyDocs[page].replace("<!--inquiry-->", inquiryForm())}</article>`;
      else {
        const renderers = {
          home,
          channels: channelList,
          channel: postList,
          search: postList,
          post,
          write,
          login,
          verify,
          me: myPage,
          notifications,
          company,
          admin,
          auth: async () =>
            session
              ? (location.replace(afterLoginTarget()),
                `<section class="auth-box"><h1>로그인을 확인했어요</h1><p>이어서 하던 화면으로 이동합니다.</p><a class="btn btn-primary" href="/me.html">내 정보로 이동</a></section>`)
              : `<section class="auth-box"><h1>로그인을 완료하지 못했어요</h1><p>${/exchange|server_error/i.test(location.search + location.hash) ? "Google 로그인 연결에 문제가 있어 운영팀이 확인 중입니다. 잠시 이메일 로그인을 이용해 주세요." : /error/.test(location.search + location.hash) ? "로그인이 취소되었거나 링크가 만료되었어요. 다시 시도해 주세요." : "링크가 만료되었거나 이미 사용되었을 수 있습니다."}</p><a class="btn btn-primary" href="/login.html">다시 로그인</a></section>`,
          missing: async () =>
            `<section class="section"><h1>페이지를 찾을 수 없어요</h1><p>주소를 확인하거나 홈에서 다시 시작해 주세요.</p><a class="btn btn-primary" href="/index.html">홈으로</a></section>`,
        };
        html = await (renderers[page] || renderers.missing)();
      }
      if (stamp !== renderId) return;
      layout();
      $("#content").innerHTML = html;
      fillAside(stamp);
      fillMorePosts(stamp);
      {
        const chips = $(".chan-chips"),
          on = chips && $(".active", chips);
        if (on) chips.scrollLeft = Math.max(0, on.offsetLeft - (chips.clientWidth - on.offsetWidth) / 2);
      }
      updatePreview();
      updateDisplay();
    } catch (err) {
      if (stamp !== renderId) return;
      layout();
      $("#content").innerHTML =
        `<section class="section"><h1>${/fetch|network|Failed|Load failed/i.test(String(err?.message || "")) ? "인터넷 연결을 확인해 주세요" : "요청을 처리하지 못했어요"}</h1><p class="error" role="alert">${E(safeError(err))}</p>${btn("다시 시도", "refresh", "", true)} <a class="btn" href="/index.html">홈으로</a></section>`;
    }
  }
  async function requireWriting(why = "") {
    if (session) mine = await read("me");
    if (isVerified()) return true;
    if (session && isActive() && ["bookmark", "follow"].includes(why)) return true;
    closeDialog();
    if (!session) {
      location.href = loginUrl(here(), why);
      return false;
    }
    await refresh();
    notify(
      viewer?.status === "suspended"
        ? "이용 정지 상태에서는 작성할 수 없어요. 내 정보의 운영 안내를 확인해 주세요."
        : why === "like"
          ? "좋아요는 설계사 인증을 마친 뒤 누를 수 있어요. 인증 신청·보완을 확인해 주세요."
          : "설계사 인증을 마친 뒤 이용할 수 있어요. 인증 신청·보완을 확인해 주세요.",
    );
    return false;
  }
  async function clickAction(el, event) {
    const action = el.dataset.do,
      id = el.dataset.id;
    if (
      [
        "reply",
        "comment-edit",
        "review-new",
        "review-edit",
        "post-delete",
        "comment-delete",
        "review-delete",
      ].includes(action) &&
      !(await requireWriting())
    )
      return;
    if (action === "report" && session && !isActive()) {
      notify("이용 정지 상태에서는 신고할 수 없어요. 운영 안내에서 이의신청 방법을 확인해 주세요.");
      return;
    }
    switch (action) {
      case "refresh":
        return refresh();
      case "dialog-close":
        return closeDialog();
      case "tip":
        el.setAttribute("aria-expanded", el.getAttribute("aria-expanded") === "true" ? "false" : "true");
        return;
      case "google":
        if (window.BL_CONFIG?.googleReady === false) {
          notify("Google 로그인 연결 준비 중입니다. 이메일로 계속해 주세요.");
          return;
        }
        return await sb.auth
          .signInWithOAuth({
            provider: "google",
            options: { redirectTo: location.origin + uri("auth.html", { returnTo: rememberReturn() }) },
          })
          .then(({ error }) => {
            if (error) throw error;
          });
      case "logout":
        return logout();
      case "toggle": {
        // 누른 자리에서 색과 숫자만 바로 바꾼다(화면 전체를 다시 그리지 않음). 서버가 거절하면 원래대로 되돌린다.
        const kind = el.dataset.kind,
          target = el.dataset.target;
        if (!session) {
          location.href = loginUrl(here(), kind);
          return;
        }
        if (!isVerified() && !(isActive() && ["bookmark", "follow"].includes(kind))) {
          notify(
            viewer?.status === "suspended"
              ? "이용 정지 상태에서는 이용할 수 없어요. 내 정보의 운영 안내를 확인해 주세요."
              : kind === "like"
                ? "좋아요는 설계사 인증을 마친 뒤 누를 수 있어요. 인증 신청·보완을 확인해 주세요."
                : "설계사 인증을 마친 뒤 이용할 수 있어요. 인증 신청·보완을 확인해 주세요.",
          );
          return;
        }
        const was = el.getAttribute("aria-pressed") === "true";
        const same = `[data-do="toggle"][data-target="${target}"][data-kind="${kind}"][data-id="${CSS.escape(id)}"]`;
        const paint = (active) => {
          $$(same).forEach((b) => {
            const before = b.getAttribute("aria-pressed") === "true";
            if (before === active) return;
            b.setAttribute("aria-pressed", String(active));
            const n = $("[data-count]", b);
            if (n) {
              n.dataset.count = String(Math.max(0, (Number(n.dataset.count) || 0) + (active ? 1 : -1)));
              n.textContent = num(n.dataset.count);
            }
            if (b.dataset.on) ($("[data-label]", b) || b).textContent = active ? b.dataset.on : b.dataset.off;
            if (active) {
              b.classList.remove("toggle-pop");
              void b.offsetWidth;
              b.classList.add("toggle-pop");
            }
          });
          if (kind === "follow")
            $$(`[data-followers="${CSS.escape(id)}"]`).forEach((f) => {
              const base = Number(f.dataset.base) || 0,
                first = f.dataset.first === "true";
              f.textContent = `팔로워 ${Math.max(0, base + (active === first ? 0 : active ? 1 : -1))}명`;
            });
          // 화면이 기억하는 값도 맞춰 둔다(댓글 정렬을 바꿔 다시 그릴 때 쓰임)
          const item = target === "post" ? current?.post : target === "comment" ? current?.comments?.find((c) => c.id === id) : null;
          if (item && item.id === id) {
            if (kind === "like") {
              if (!!item.liked !== active) item.likes = Math.max(0, (Number(item.likes) || 0) + (active ? 1 : -1));
              item.liked = active;
            } else if (kind === "bookmark") item.bookmarked = active;
          }
        };
        paint(!was);
        try {
          const r = await act("toggle", { target, id, kind });
          if (typeof r.active === "boolean" && r.active !== !was) paint(r.active);
        } catch (err) {
          paint(was);
          throw err;
        }
        return;
      }
      case "share":
        try {
          await navigator.clipboard.writeText(location.origin + uri("post.html", { id: params.get("id") }));
          notify("공개 글 주소를 복사했어요.");
        } catch {
          dialog(
            `<h2>글 주소</h2><p>아래 주소를 복사해 공유해 주세요.</p><input readonly aria-label="공유 주소" value="${E(location.origin + uri("post.html", { id: params.get("id") }))}"><div class="modal-actions">${btn("닫기", "dialog-close")}</div>`,
          );
        }
        return;
      case "report":
        if (!session) {
          location.href = loginUrl(here(), "report");
          return;
        }
        if (!isVerified() && !isAdmin()) {
          notify("신고는 설계사 인증을 마친 회원만 할 수 있어요. 인증 신청 후 이용해 주세요.");
          return;
        }
        return reportDialog(el.dataset.target, id);
      case "appeal":
        return reportDialog(el.dataset.target, id, true);
      case "review-delete":
        return confirmation(
          "review_delete",
          id,
          "리뷰 삭제",
          "내 리뷰를 삭제하면 회사의 유효 리뷰 집계에서도 제외됩니다.",
        );
      case "post-delete":
        return confirmation("post_delete", id, "글 삭제", "삭제하면 이 글은 더 이상 표시되지 않습니다.");
      case "comment-delete":
        return confirmation("comment_delete", id, "댓글 삭제", "작성한 댓글을 삭제합니다.");
      case "withdraw":
        return confirmation(
          "withdraw",
          "",
          "회원 탈퇴",
          "탈퇴 즉시 회원 전용 접근이 차단됩니다. 남은 글과 댓글은 ‘탈퇴한 회원’으로 표시됩니다.",
        );
      case "reply": {
        const slot = $(`[data-reply-slot="${CSS.escape(id)}"]`);
        if (slot.firstChild) {
          slot.innerHTML = "";
          return;
        }
        $$("[data-reply-slot]").forEach((x) => (x.innerHTML = ""));
        slot.innerHTML = `<form data-form="comment" class="comment-form reply-form open"><input type="hidden" name="post_id" value="${E(current.post.id)}"><input type="hidden" name="parent_id" value="${E(id)}"><textarea name="body" rows="2" aria-label="대댓글" placeholder="대댓글을 남겨 주세요." required maxlength="3000" data-testid="reply-body"></textarea><p class="error" data-form-error role="alert"></p><div class="comment-form-actions"><button type="button" class="btn btn-small" data-do="reply-cancel">취소</button><button class="btn btn-primary btn-small" type="submit">등록</button></div></form>`;
        slot.querySelector("textarea").focus();
        return;
      }
      case "reply-cancel":
        el.closest("[data-reply-slot]").innerHTML = "";
        return;
      case "comment-cancel": {
        const form = el.closest("form");
        form.reset();
        form.classList.remove("open");
        const err = $("[data-form-error]", form);
        if (err) err.textContent = "";
        return;
      }
      case "comment-sort": {
        try {
          localStorage.setItem("bl_comment_sort", el.dataset.sort);
        } catch {}
        $$('[data-do="comment-sort"]').forEach((b) => {
          const on = b.dataset.sort === el.dataset.sort;
          b.classList.toggle("active", on);
          b.setAttribute("aria-pressed", String(on));
        });
        const list = $("[data-comment-list]");
        if (list && current?.post) list.innerHTML = commentListHTML(current);
        return;
      }
      case "ai-more": {
        const body = $("#ai-body"),
          open = body.classList.toggle("clamp") === false;
        el.textContent = open ? "접기" : "더보기";
        el.setAttribute("aria-expanded", String(open));
        return;
      }
      case "comment-edit": {
        const c = current?.comments?.find((c) => c.id === id);
        if (!c) return;
        dialog(
          `<h2>댓글 수정</h2><form data-form="comment"><input type="hidden" name="id" value="${E(c.id)}"><input type="hidden" name="post_id" value="${E(c.post_id)}">${area("body", "댓글 내용", c.body, 'required maxlength="3000"')}${formEnd("수정 저장")}<p></p>${btn("취소", "dialog-close")}</form>`,
        );
        return;
      }
      case "review-new":
        return reviewDialog({}, id);
      case "review-edit": {
        const r = current?.reviews?.find((r) => r.id === id);
        if (r) return reviewDialog(r);
        return;
      }
      case "notifications-read":
        await act("notification_read");
        return refresh();
      case "notification-read":
        await act("notification_read", { id });
        return refresh();
      case "notification-open":
        event.preventDefault();
        await act("notification_read", { id });
        location.href = el.href;
        return;
      case "more-posts": {
        const d = await read("posts", { ...current.list.args, offset: current.list.offset });
        const more = d.posts || [];
        $("[data-post-list]").insertAdjacentHTML("beforeend", more.map((p) => feed(p, current.list.opts)).join(""));
        current.list.offset += more.length;
        if (more.length < 20) el.closest(".more-wrap")?.remove();
        return;
      }
      case "admin-more": {
        const sec = el.dataset.section;
        const d = await read("admin", { ...current.args, offset: current.offset });
        const list = $(`[data-admin-list="${CSS.escape(sec)}"]`);
        if (list) list.insertAdjacentHTML("beforeend", (d.items || []).map(adminRows[sec]).join(""));
        current.offset += (d.items || []).length;
        if ((d.items || []).length < 30) el.closest(".more-wrap")?.remove();
        return;
      }
      case "admin-dialog": {
        const kind = el.dataset.kind,
          mode = el.dataset.mode;
        const items = kind === "channel" ? current?.admin?.channels || [] : current?.admin?.companies || [];
        const item = items.find((x) => x.id === id) || {};
        const label = kind === "channel" ? "채널" : "보험사·GA";
        const title = mode === "add" ? `${label} 추가` : mode === "edit" ? `${label} 수정 · ${item.name}` : `${label} 삭제 · ${item.name}`;
        const form =
          mode === "delete"
            ? removalFormHTML(kind, item, items)
            : kind === "channel"
              ? channelFormHTML(mode === "add" ? {} : item)
              : companyFormHTML(mode === "add" ? {} : item);
        dialog(`<h2>${E(title)}</h2>${form}<p></p>${btn("닫기", "dialog-close")}`);
        return;
      }
      case "admin-order":
        await act("admin", { operation: el.dataset.op, id, direction: el.dataset.dir });
        return refresh();
      case "proof": {
        const d = await act("admin", { operation: "proof_access", id, reason: "인증 심사를 위한 증빙 확인" });
        const { data, error } = await sb.storage.from("bl-proofs").createSignedUrl(d.path, 60);
        if (error) throw error;
        dialog(
          `<h2>인증 증빙</h2><p class="hint">이 화면의 주소는 60초 동안 유효합니다. 증빙은 심사 목적으로만 열람해 주세요.</p><img class="proof-photo" src="${E(data.signedUrl)}" alt="신청자가 제출한 인증 증빙"><div class="modal-actions">${btn("닫기", "dialog-close")}</div>`,
        );
        setTimeout(() => {
          if ($("#dialog").open && $(".proof-photo")) {
            closeDialog();
            notify("증빙 열람 시간이 끝났습니다. 필요하면 다시 열어 주세요.");
          }
        }, 60000);
        return;
      }
    }
  }
  async function submitForm(form) {
    const data = new FormData(form),
      v = Object.fromEntries(data),
      type = form.dataset.form;
    // 관리자의 운영팀 이름 글은 설계사 인증과 상관없이 쓸 수 있다(서버도 같은 규칙).
    const teamPost = type === "post" && isAdmin() && data.has("as_team");
    if (
      (["post", "comment", "review"].includes(type) ||
        (type === "confirm" && ["post_delete", "comment_delete", "review_delete"].includes(v.action))) &&
      !teamPost &&
      !(await requireWriting())
    )
      return;
    if (type === "admin" && !window.confirm(adminConfirmText(form))) return;
    if (type === "admin") {
      mine = await read("me");
      if (!isAdmin()) {
        await refresh();
        throw new Error("관리자 권한이 필요합니다.");
      }
    }
    switch (type) {
      case "email": {
        const { error } = await sb.auth.signInWithOtp({
          email: v.email.trim(),
          options: {
            emailRedirectTo: location.origin + uri("auth.html", { returnTo: rememberReturn() }),
            shouldCreateUser: true,
          },
        });
        if (error) throw error;
        $("#otp-area").hidden = false;
        notify("로그인 메일을 요청했어요. 받은편지함과 스팸함을 확인해 주세요.");
        return;
      }
      case "otp": {
        const email = $("#email-form").elements.email.value.trim();
        const { error } = await sb.auth.verifyOtp({ email, token: v.token.trim(), type: "email" });
        if (error) throw error;
        location.href = afterLoginTarget();
        return;
      }
      case "verification": {
        const file = data.get("proof");
        if (!file?.size) throw new Error("증빙 사진을 선택해 주세요.");
        if (file.size > 5 * 1024 * 1024 || !["image/jpeg", "image/png", "image/webp"].includes(file.type))
          throw new Error("증빙은 JPG·PNG·WebP, 5MB 이하 파일만 올릴 수 있어요.");
        const payload = {
          name: v.name.trim(),
          nickname: v.nickname.trim(),
          phone: v.phone.trim(),
          registration_number: v.registration_number.replace(/\D/g, ""),
        };
        if (v.company_id === "custom") {
          payload.company_id = null;
          payload.company_name = v.company_name.trim();
        } else payload.company_id = v.company_id;
        // 사진을 올리기 전에 서버에서 입력부터 검사한다.
        const check = await act("profile_precheck", payload);
        if (check.proof_slots_left === 0)
          throw new Error(
            check.cleaning
              ? "이전에 올린 사진을 정리하고 있어요. 2~3분 뒤 다시 신청해 주세요."
              : "증빙 사진을 5장까지 올려서 더 올릴 수 없어요. 제출하지 않은 사진은 자동으로 정리되니 잠시 뒤 다시 시도해 주세요.",
          );
        const ext = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" }[file.type];
        const path = `${session.user.id}/${crypto.randomUUID()}.${ext}`;
        const { error } = await sb.storage
          .from("bl-proofs")
          .upload(path, file, { upsert: false, contentType: file.type });
        if (error) throw proofUploadError(error);
        try {
          await act("profile_submit", { ...payload, proof_path: path });
        } catch (err) {
          await act("proof_discard", { proof_path: path }).catch(() => {});
          throw err;
        }
        if (proofPreview) URL.revokeObjectURL(proofPreview);
        notify("인증 신청을 접수했어요.");
        location.href = "/me.html";
        return;
      }
      case "inquiry":
        await act("inquiry", { kind: v.kind, link: (v.link || "").trim(), body: v.body.trim() });
        form.reset();
        notify("문의를 보냈어요. 답변은 알림으로 알려 드려요.");
        return;
      case "profile":
        await act("profile_update", { nickname: v.nickname.trim() });
        notify("닉네임을 변경했어요.");
        return refresh();
      case "post": {
        const payload = {
          channel_id: v.channel_id,
          title: v.title.trim(),
          body: v.body.trim(),
          content_kind: v.content_kind,
          is_question: data.has("is_question"),
        };
        if (form.elements.as_team) payload.as_team = data.has("as_team");
        if (form.elements.pinned) payload.pinned = data.has("as_team") && data.has("pinned");
        if (v.id) payload.id = v.id;
        if (v.company_id) payload.company_id = v.company_id;
        const result = await act("post_save", payload);
        location.href = uri("post.html", { id: result.id || v.id });
        return;
      }
      case "comment": {
        const payload = { post_id: v.post_id, body: (v.body || v["reply-body"] || "").trim() };
        if (v.id) payload.id = v.id;
        if (v.parent_id) payload.parent_id = v.parent_id;
        const saved = await act("comment_save", payload);
        closeDialog();
        notify(v.id ? "댓글을 수정했어요." : "댓글을 등록했어요.");
        return reloadComments(saved.id || v.id);
      }
      case "report": {
        const types = {
          privacy: "개인정보 노출",
          defamation: "명예훼손·허위사실",
          spam: "광고·도배",
          abuse: "욕설·혐오·괴롭힘",
          appeal: "처리 결과 이의신청",
          other: "기타 권리침해",
        };
        const reported = await act(v.reason_type === "appeal" ? "appeal" : "report", {
          target: v.target,
          id: v.id.trim(),
          reason: `[${types[v.reason_type] || "신고"}] ${v.reason_detail.trim()}`,
        });
        closeDialog();
        notify(
          v.reason_type === "appeal"
            ? "이의신청을 접수했어요. 운영자가 소명을 검토합니다."
            : reported.hidden
              ? "신고가 여러 건 모여 운영자 판단 전까지 임시로 가렸어요."
              : "신고를 접수했어요. 운영자가 검토한 뒤 알림으로 알려 드려요.",
        );
        return refresh();
      }
      case "review": {
        const payload = {
          company_id: v.company_id,
          title: v.title.trim(),
          body: v.body.trim(),
          scores: scoreNames.map((_, i) => Number(v["score_" + i])),
        };
        if (v.id) payload.id = v.id;
        await act("review_save", payload);
        closeDialog();
        notify("리뷰를 저장했어요.");
        return refresh();
      }
      case "confirm": {
        await act(v.action, v.id ? { id: v.id } : {});
        closeDialog();
        if (v.action === "withdraw") {
          await sb.auth.signOut({ scope: "local" }).catch(() => {});
          clearLocalSession();
          location.href = "/index.html";
        } else if (v.action === "post_delete") location.href = "/channel.html";
        else if (v.action === "comment_delete" && page === "post") {
          notify("댓글을 삭제했어요.");
          return reloadComments();
        } else {
          notify("처리했어요.");
          return refresh();
        }
        return;
      }
      case "admin": {
        const payload = { ...v };
        if (!payload.id) delete payload.id;
        delete payload.confirm_delete;
        delete payload.confirm_withdraw;
        ["enabled", "pinned", "anonymous"].forEach((k) => {
          if (form.elements[k]) payload[k] = data.has(k);
        });
        ["display_order", "daily_limit", "days"].forEach((k) => {
          if (k in payload && payload[k] !== "") payload[k] = Number(payload[k]);
        });
        if (payload.operation === "channel_save" && !payload.slug)
          payload.slug = slugify(payload.name, (current?.admin?.channels || channels).map((c) => c.slug));
        const done = await act("admin", payload);
        if (payload.operation === "reveal_author") {
          const a = done.author || {};
          dialog(
            `<h2>익명 작성자</h2><p>${E(a.nickname || "닉네임 없음")} · ${E(a.company_name || "소속 미등록")} · ${E(statusNames[a.status] || "")}</p><p class="hint">확인한 사실과 사유가 감사 기록에 남았어요. 다른 사람에게 알리지 마세요.</p><div class="modal-actions"><a class="btn" href="${uri("admin/", { section: "members", id: a.member_id })}">회원 상세</a>${btn("닫기", "dialog-close")}</div>`,
          );
          return;
        }
        closeDialog();
        notify("저장했어요. 처리 내역은 감사 기록에 남았어요.");
        return refresh();
      }
    }
  }
  document.addEventListener("click", async (event) => {
    const el = event.target.closest("[data-do]");
    if (!el) return;
    event.preventDefault();
    if (el.disabled) return;
    el.disabled = true;
    try {
      await clickAction(el, event);
    } catch (err) {
      notify(safeError(err));
    } finally {
      if (el.isConnected) el.disabled = false;
    }
  });
  document.addEventListener("click", (event) => {
    $$("details.more-menu[open]").forEach((m) => {
      if (!m.contains(event.target) || event.target.closest(".more-list a, .more-list button")) m.open = false;
    });
  });
  document.addEventListener("submit", async (event) => {
    const form = event.target.closest("form[data-form]");
    if (!form) return;
    event.preventDefault();
    if (!form.reportValidity()) return;
    const error = $("[data-form-error]", form);
    if (error) error.textContent = "";
    const button = $("button[type=submit]", form);
    if (button?.disabled) return;
    if (button) button.disabled = true;
    try {
      await submitForm(form);
    } catch (err) {
      const msg = safeError(err);
      if (error?.isConnected) error.textContent = msg;
      else notify(msg);
    } finally {
      if (button?.isConnected) button.disabled = false;
    }
  });
  document.addEventListener("focusin", (event) => {
    event.target.closest?.("form.comment-form")?.classList.add("open");
  });
  document.addEventListener("input", (event) => {
    const fmt = event.target.dataset?.format;
    if (fmt === "phone") {
      event.target.value = formatPhone(event.target.value);
      const n = event.target.value.replace(/\D/g, "").length;
      event.target.setCustomValidity(!n || (n >= 9 && n <= 11) ? "" : "연락처를 확인해 주세요. 예: 010-1234-5678");
    } else if (fmt === "digits") {
      event.target.value = event.target.value.replace(/\D/g, "").slice(0, 14);
      const n = event.target.value.length;
      event.target.setCustomValidity(
        !n || n === 14 ? "" : `설계사 고유번호는 숫자 14자리예요. 지금 ${n}자리입니다.`,
      );
    }
    if (event.target.closest("#post-form")) updatePreview();
    if (event.target.closest('form[data-form="verification"]')) updateDisplay();
  });
  document.addEventListener("change", (event) => {
    if (event.target.name === "proof") {
      if (proofPreview) URL.revokeObjectURL(proofPreview);
      const f = event.target.files?.[0];
      const img = $("#proof-preview");
      if (img) {
        img.hidden = !f;
        if (f) {
          proofPreview = URL.createObjectURL(f);
          img.src = proofPreview;
        }
      }
    }
    updatePreview();
    updateDisplay();
  });
  $("#dialog").addEventListener("click", (event) => {
    if (event.target === $("#dialog")) closeDialog();
  });
  let checking = false;
  async function revalidate() {
    if (checking || !sb || !session || document.visibilityState === "hidden") return;
    checking = true;
    const before = `${viewer?.status}/${viewer?.role}`;
    try {
      const r = await sb.auth.getSession();
      if (!r.data.session) {
        session = null;
        viewer = null;
        mine = null;
        closeDialog();
        await refresh();
        return;
      }
      const d = await read("me");
      mine = d;
      if (`${viewer?.status}/${viewer?.role}` !== before) {
        closeDialog();
        await refresh();
      }
    } catch {
      viewer = null;
      mine = null;
      closeDialog();
      $("#content").innerHTML =
        `<section class="section"><h1>회원 상태를 다시 확인해 주세요</h1><p>권한 확인이 끝나지 않아 회원 내용을 가렸습니다.</p>${btn("다시 확인", "refresh", "", true)}</section>`;
    } finally {
      checking = false;
    }
  }
  window.addEventListener("focus", revalidate);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") revalidate();
  });
  setInterval(revalidate, 60000);
  async function boot() {
    layout();
    if (!window.supabase || !window.BL_CONFIG?.url || !window.BL_CONFIG?.anonKey) {
      if (policyDocs[page]) {
        $("#content").innerHTML = `<article class="section policy">${policyDocs[page]}</article>`;
        return;
      }
      $("#content").innerHTML =
        '<section class="section"><h1>서비스 연결을 준비하고 있어요</h1><p>잠시 후 다시 방문해 주세요.</p><a class="btn" href="/rules.html">운영정책 보기</a></section>';
      return;
    }
    sb = window.supabase.createClient(window.BL_CONFIG.url, window.BL_CONFIG.anonKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
      global: { headers: { "x-client-info": "bohumlive-web/1.0" } },
    });
    sb.auth.onAuthStateChange((event, newSession) => {
      if (event === "INITIAL_SESSION") return;
      if (event === "SIGNED_OUT") {
        session = null;
        viewer = null;
        mine = null;
        current = null;
        closeDialog();
        $("#content").innerHTML = '<div class="loading">로그아웃 상태를 확인하고 있습니다.</div>';
        setTimeout(refresh, 0);
      } else if (event === "SIGNED_IN" && page === "auth") {
        session = newSession;
        setTimeout(() => location.replace(afterLoginTarget()), 0);
      } else if (event === "TOKEN_REFRESHED") setTimeout(revalidate, 0);
    });
    await refresh();
    try {
      const flash = sessionStorage.getItem("bl_flash");
      if (flash) {
        sessionStorage.removeItem("bl_flash");
        notify(flash);
      }
    } catch {}
  }
  boot();
})();
