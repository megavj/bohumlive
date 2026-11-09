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
      ? new Date(v).toLocaleString("ko-KR", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })
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
  const sampleBadge = (p) => (p?.is_sample ? '<span class="tag sample-badge">임시 견본</span>' : "");
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
    if (/fetch|network|Failed|Load failed/i.test(msg))
      return "연결하지 못했어요. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.";
    if (/rate|over_email_send_rate_limit|429/i.test(msg))
      return "요청이 너무 많아요. 잠시 후 다시 시도해 주세요. 이메일은 무료 발송 한도가 적용됩니다.";
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
    $("#header").innerHTML =
      `<header class="site-header"><div class="header-inner"><div class="topbar"><a class="wordmark" href="/index.html" aria-label="보험라이브 홈"><img class="wm-logo" src="/assets/logo-live.gif?v=20261109" alt="보험라이브" width="320" height="96" decoding="async" fetchpriority="high"></a><form class="header-search" action="/search.html" role="search"><input aria-label="검색어" name="q" placeholder="관심 있는 내용을 검색해 보세요" value="${page === "search" ? E(params.get("q") || "") : ""}" maxlength="100"><button aria-label="검색">${icon("search")}</button></form>${session ? `<div class="header-user" data-testid="header-user"><a class="notification-link" href="/notifications.html" aria-label="${viewer?.unread_count ? `알림 ${Number(viewer.unread_count)}개 안 읽음` : "알림"}">${icon("bell")}${viewer?.unread_count ? `<span class="notification-count" data-testid="unread-count">${Number(viewer.unread_count) > 99 ? "99+" : Number(viewer.unread_count)}</span>` : ""}</a><a class="header-name" href="/me.html" title="내 정보">${E(displayName())}님</a><span class="header-sep" aria-hidden="true">·</span><button type="button" class="header-logout" data-do="logout" data-testid="header-logout">로그아웃</button></div>` : page === "login" ? "" : `<a class="header-login" href="${E(loginUrl())}">로그인·가입</a>`}</div><nav class="primary-nav" aria-label="주 메뉴"><a class="${active === "home" ? "active" : ""}" href="/index.html">홈</a><a class="${active === "channels" ? "active" : ""}" href="/channels.html">채널</a><a class="${active === "company" ? "active" : ""}" href="/company.html">보험사 리뷰</a>${isAdmin() ? `<a class="${page === "admin" ? "active" : ""}" href="/admin/" data-testid="admin-nav">관리자</a>` : ""}</nav>${isOwner() ? '<p class="status-banner" data-testid="owner-permissions">대표 관리자 · 모든 권한 · 인증 면제</p>' : ""}</div></header>`;
    $("#footer").innerHTML =
      `<footer class="site-footer"><div class="footer-logo">보험<b style="color:var(--accent)">라이브</b></div><nav class="footer-links" aria-label="서비스 정책"><a href="/terms.html">이용약관</a><a href="/privacy.html">개인정보처리방침</a><a href="/rules.html">커뮤니티 운영정책</a><a href="/help.html">이용 도움말·권리침해 신고</a></nav><p class="footer-note">보험라이브는 설계사의 경험과 실무 지식을 나누는 공간입니다. 회원의 글은 개인의 의견이며 회사의 공식 입장이나 보험상품 가입 권유가 아닙니다. 고객정보·주민등록번호·개인 연락처를 게시하지 마세요.</p><p class="footer-note">공개 준비 중 · 검색 노출을 차단하고 있습니다.</p></footer>`;
    $("#sidebar").innerHTML =
      `<section class="sidebar-block"><h2>동료의 경험이 필요할 때</h2><p class="muted">궁금한 내용을 질문하고<br>설계사 동료의 답변을 만나 보세요.</p><a class="btn btn-primary" href="/write.html">${icon("edit")} 글쓰기</a></section><section class="sidebar-block"><h2>함께 지키는 약속</h2><p class="muted small">회사는 그대로, 닉네임은 첫 글자만 표시해요(완전익명 채널은 ‘익명’). 고객정보나 동료의 개인정보가 담기지 않았는지 확인해 주세요.</p><a class="text-link" href="/rules.html" target="_blank" rel="noopener">운영정책 보기 →</a></section>${session ? `<section class="sidebar-block"><h2>${isOwner() ? "나의 권한" : "나의 인증 상태"}</h2><p>${E(statusLabel())}</p><a class="text-link" href="/me.html" target="_blank" rel="noopener">내 정보 확인 →</a></section>` : ""}`;
    $("#main").classList.toggle("admin-main", page === "admin");
    if (page === "admin") $("#sidebar").hidden = true;
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
  function feed(post, compact = false) {
    return `<article class="feed-item ${compact ? "compact-item" : ""} ${post.pinned ? "feed-notice" : ""}" data-testid="post-item"><a class="feed-channel" href="${uri("channel.html", { id: post.channel_id })}">${post.pinned ? '<span class="tag">공지</span>' : ""}${E(post.channel_name || "커뮤니티")} <span class="tag">${E(kindNames[post.content_kind] || "글")}</span>${post.is_question ? '<span class="tag">질문</span>' : ""}${sampleBadge(post)}</a><a class="feed-title" href="${uri("post.html", { id: post.id })}">${E(post.title)}</a>${compact ? "" : `<p class="feed-excerpt">${E(post.body)}</p><p class="author">${E(post.author_display || "운영팀")}</p>`}<div class="meta"><span>${icon("heart")} ${Number(post.likes) || 0}</span><span>${icon("comment")} ${Number(post.comment_count) || 0}</span><span>${E(date(post.created_at))}</span></div></article>`;
  }
  const feeds = (posts, compact = false) => (posts?.length ? posts.map((p) => feed(p, compact)).join("") : empty());
  const channelDisc = (c) => `<span class="topic-disc ${E(c.slug)}">${E(c.name?.slice(0, 1) || "보")}</span>`;
  async function home() {
    const d = await read("home");
    channels = d.channels || [];
    companies = d.companies || [];
    const posts = d.posts || [];
    return `${d.notices?.length ? `<section class="home-section"><h2 class="section-title">운영 안내</h2>${feeds(d.notices, true)}</section><div class="divider"></div>` : ""}<section class="home-section"><h1 class="section-title">토픽 베스트</h1>${feeds(posts.slice(0, 10), true)}<a class="more-row" href="/channel.html?sort=popular">더보기</a></section><div class="divider"></div><section class="home-section"><h2 class="section-title">지금 많이 읽는 글</h2>${feeds(d.popular || [], true)}<a class="more-row" href="/channel.html?sort=popular">더보기</a></section><div class="divider"></div>${channels.map((c) => `<section class="home-section"><div class="home-channel-heading"><h2 class="section-title"><a class="row" href="${uri("channel.html", { id: c.id })}"><span class="topic-disc mini ${E(c.slug)}">${E(c.name.slice(0, 1))}</span>${E(c.name)}</a></h2><a href="${uri("channel.html", { id: c.id })}">더보기</a></div>${feeds(posts.filter((p) => p.channel_id === c.id).slice(0, 5), true)}</section><div class="divider"></div>`).join("")}`;
  }
  async function channelList() {
    const d = await read("channels");
    channels = d.channels || [];
    const follow = params.get("filter") === "following";
    const list = follow ? channels.filter((c) => c.following) : channels;
    return `<section class="explore"><h1>채널 탐색</h1><p class="muted">관심 있는 주제를 팔로우하고 동료의 이야기를 만나 보세요.</p><nav class="chips"><a class="chip ${!follow ? "active" : ""}" href="/channels.html">모든 채널</a><a class="chip ${follow ? "active" : ""}" href="/channels.html?filter=following">팔로우</a></nav><div class="channel-cards">${list.map((c) => `<article class="channel-card">${channelDisc(c)}<div class="channel-card-info"><h2><a href="${uri("channel.html", { id: c.id })}">${E(c.name)}</a>${c.anonymous ? ' <span class="tag anon-tag">완전 익명</span>' : ""}</h2><p>${E(c.description)}</p><p class="follow-count">팔로워 ${Number(c.followers) || 0}명</p></div><button type="button" class="follow-small" data-do="toggle" data-target="channel" data-kind="follow" data-id="${E(c.id)}" aria-pressed="${!!c.following}">${c.following ? "팔로잉" : "팔로우"}</button></article>`).join("")}</div>${!list.length ? empty("아직 팔로우한 채널이 없어요.", "모든 채널에서 관심 있는 주제를 선택해 주세요.") : ""}</section>`;
  }
  async function postList() {
    const q = params.get("q") || "";
    let id = params.get("id") || "";
    const cd = await read("channels");
    channels = cd.channels || [];
    if (!id && params.get("channel")) id = channels.find((c) => c.slug === params.get("channel"))?.id || "";
    const channel = channels.find((c) => c.id === id);
    const sort = params.get("sort") === "popular" ? "popular" : "latest";
    const d = await read("posts", { ...(id ? { channel_id: id } : {}), ...(q ? { q } : {}), sort, limit: 50 });
    const posts = d.posts || [];
    const isSearch = page === "search";
    return `<section class="section"><div class="section-head"><h1>${isSearch ? "검색 결과" : E(channel?.name || "모든 글")}${channel?.anonymous ? ' <span class="tag anon-tag">완전 익명</span>' : ""}</h1><a class="btn btn-primary btn-small" href="${uri("write.html", id ? { channel: id } : {})}">글쓰기</a></div>${isSearch ? `<form class="search-form" action="/search.html"><input name="q" aria-label="검색할 내용" value="${E(q)}" maxlength="100" placeholder="궁금한 내용을 검색하세요" required><button class="btn" type="submit">검색</button></form><p class="muted small">${q ? `“${E(q)}” 검색 결과 ${posts.length}개` : "검색어를 입력해 주세요."}</p>` : `<p class="muted">${E(channel?.description || "설계사의 경험과 실무 이야기를 함께 나눠요.")}</p>${channel?.anonymous ? '<p class="notice small">이 채널의 글과 댓글은 회사명·닉네임 없이 ‘익명’으로만 보여요. 운영자는 신고 처리 때만 기록을 남기고 작성자를 확인합니다.</p>' : ""}${channel ? btn(channel.following ? "팔로잉" : "팔로우", "toggle", `data-target="channel" data-kind="follow" data-id="${E(channel.id)}" aria-pressed="${!!channel.following}"`) : ""}`}</section><nav class="tabs"><a class="${sort === "latest" ? "active" : ""}" href="${uri(isSearch ? "search.html" : "channel.html", { ...(id ? { id } : {}), ...(q ? { q } : {}), sort: "latest" })}">최신순</a><a class="${sort === "popular" ? "active" : ""}" href="${uri(isSearch ? "search.html" : "channel.html", { ...(id ? { id } : {}), ...(q ? { q } : {}), sort: "popular" })}">인기순</a></nav>${isSearch && !q ? empty("궁금한 내용을 찾아보세요.", "제목과 공개 범위에 맞는 본문을 검색합니다.") : feeds(posts)}`;
  }
  function commentHTML(c) {
    return `<article class="comment-item ${c.parent_id ? "comment-reply" : ""}" id="comment-${E(c.id)}" data-testid="comment-item"><div class="comment-author">${E(c.author_display)} ${c.is_mine ? '<span class="author-badge">내 댓글</span>' : ""} ${sampleBadge(c)}</div><p class="body-text">${E(c.body)}</p><div class="meta"><span>${E(date(c.created_at))}</span><button data-do="toggle" data-target="comment" data-kind="like" data-id="${E(c.id)}" aria-pressed="${!!c.liked}" ${c.is_mine ? 'disabled title="내 댓글에는 좋아요를 누를 수 없어요"' : ""}>${icon("heart")} ${Number(c.likes) || 0}</button>${!c.parent_id && isVerified() ? `<button data-do="reply" data-id="${E(c.id)}">답글</button>` : ""}${c.is_mine && isVerified() ? `<button data-do="comment-edit" data-id="${E(c.id)}">수정</button><button data-do="comment-delete" data-id="${E(c.id)}">삭제</button>` : ""}${c.is_mine ? "" : `<button data-do="report" data-target="comment" data-id="${E(c.id)}">신고</button>`}</div><div data-reply-slot="${E(c.id)}"></div></article>`;
  }
  async function post() {
    const id = params.get("id");
    if (!id) return empty("글을 선택해 주세요.", "홈이나 채널에서 읽을 글을 선택할 수 있어요.");
    const d = await read("post", { id });
    current = d;
    const p = d.post;
    if (!p)
      return `<section class="section"><h1>${d.unavailable_reason === "temporary_hidden" ? "운영 검토를 위해 임시 가림한 글입니다" : "글을 표시할 수 없어요"}</h1><p class="notice">이 글은 삭제되었거나 신고 접수에 따른 운영 검토로 가려졌습니다. 임시조치는 접수 후 최대 30일 안에 검토합니다.${d.hidden_until ? `<br>검토 예정: ${E(date(d.hidden_until))}` : ""}</p><a class="btn" href="/channel.html">다른 글 보기</a><a class="btn" href="/help.html">신고·이의신청 안내</a>${session ? btn("내 글 조치에 이의신청", "appeal", `data-target="post" data-id="${E(id)}"`) : ""}</section>`;
    const comments = d.comments || [];
    const ordered = comments
      .filter((c) => !c.parent_id)
      .flatMap((c) => [c, ...comments.filter((x) => x.parent_id === c.id)]);
    return `<article><header class="post-header"><div class="breadcrumb"><a href="/channels.html">채널</a><span>›</span><a href="${uri("channel.html", { id: p.channel_id })}">${E(p.channel_name)}</a><span class="tag">${E(kindNames[p.content_kind])}</span>${p.is_question ? '<span class="tag">질문</span>' : ""}${sampleBadge(p)}</div><h1>${E(p.title)}</h1><p class="post-author"><span class="company-name">${E(p.author_display)}</span></p><div class="meta"><span>${E(date(p.created_at))}</span><span>${icon("comment")} 사람 댓글 ${Number(p.comment_count) || 0}</span>${p.is_mine && isVerified() ? `<a href="${uri("write.html", { id: p.id })}">수정</a><button data-do="post-delete" data-id="${E(p.id)}">삭제</button>` : ""}${p.is_mine ? "" : `<button class="push" data-do="report" data-target="post" data-id="${E(p.id)}">신고</button>`}</div></header><div class="post-body body-text" data-testid="post-body">${E(p.body)}</div>${p.is_truncated ? '<div class="guest-lock"><h2>여기부터 인증 회원에게만 공개</h2><p>설계사 인증 후 나머지 본문과 동료의 댓글을 읽을 수 있어요.</p>${verifyLink()}</div>' : ""}<div class="post-actions"><button data-do="toggle" data-target="post" data-kind="like" data-id="${E(p.id)}" aria-pressed="${!!p.liked}" ${p.is_mine ? 'disabled title="내 글에는 좋아요를 누를 수 없어요"' : ""} data-testid="post-like">${icon("heart")} 좋아요 ${Number(p.likes) || 0}</button><button data-do="toggle" data-target="post" data-kind="bookmark" data-id="${E(p.id)}" aria-pressed="${!!p.bookmarked}" data-testid="post-bookmark">${icon("bookmark")} ${p.bookmarked ? "저장됨" : "북마크"}</button><button data-do="share" class="share-button" aria-label="글 링크 복사">${icon("share")}</button></div>${p.company_id ? `<section class="related-companies"><h2>관련 회사</h2><a class="related-company" href="${uri("company.html", { id: p.company_id })}"><span class="company-mark">${E(p.company_name)}</span><p>${E(p.company_name)}<br><span class="muted small">회사 정보와 리뷰 보기</span></p></a></section>` : ""}<section class="comments"><div class="comments-top"><h2>댓글 ${Number(p.comment_count) || 0}</h2>${isVerified() ? `<form data-form="comment" class="comment-form"><input type="hidden" name="post_id" value="${E(p.id)}"><label class="sr-only" for="comment-body">댓글</label><textarea id="comment-body" name="body" placeholder="고객정보 없이 동료의 경험을 나눠 주세요." required maxlength="3000" data-testid="comment-body"></textarea><p class="error" data-form-error role="alert"></p><button class="btn btn-primary btn-small" type="submit">댓글 등록</button></form>` : canReadMember() ? '<p class="notice">관리자 운영 권한으로 댓글과 AI 답변을 읽을 수 있어요. 글·댓글·리뷰 작성은 설계사 인증 후 이용해 주세요. <a href="/verify.html">인증 신청·보완하기</a></p>' : `<div class="guest-lock">${icon("lock")}<h2>댓글과 AI 답변은 인증 회원에게 공개돼요</h2><p>${session ? `현재 상태: ${E(statusLabel())}` : "로그인 후 설계사 인증을 완료해 주세요."}</p>${viewer?.status === "suspended" ? '<a class="btn btn-primary" href="/help.html">이용 정지 안내</a>' : verifyLink()}</div>`}</div>${canReadMember() ? (ordered.length ? ordered.map(commentHTML).join("") : empty("아직 동료의 댓글이 없어요.", "첫 경험이나 의견을 남겨 주세요.")) : ""}${d.ai_reply ? `<article class="comment-item comment-ai" data-testid="ai-reply"><div class="comment-author">보험라이브 AI 참고 답변 <span class="ai-badge">AI</span></div><p class="body-text">${E(d.ai_reply.body)}</p><p class="source-note">AI가 작성한 참고 정보입니다. 약관·공식 자료와 현재 기준을 직접 확인하세요. 사람 댓글과 인기 집계에는 포함되지 않습니다.</p></article>` : ""}</section></article>`;
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
      channels.map((c) => [c.id, c.name]),
      p.channel_id || params.get("channel"),
      "required",
    )}${select(
      "content_kind",
      "공개 범위",
      Object.entries(kindNames).filter(([k]) => k !== "weekly" || isAdmin()),
      p.content_kind || "experience",
      "required",
    )}${select("company_id", "관련 회사 (선택)", [["", "선택하지 않음"], ...companies.map((c) => [c.id, c.name])], p.company_id || "")}</div><label class="check-line"><input type="checkbox" name="is_question" ${p.is_question ? "checked" : ""}>동료에게 묻는 질문입니다. AI 참고 답변이 함께 생성될 수 있어요.</label>${
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
    return `<section class="auth-box"><a class="back-link" href="/index.html">← 보험라이브 홈</a><h1>로그인</h1><p class="small muted login-first">처음이면 로그인할 때 자동으로 가입돼요. 따로 가입할 필요가 없어요.</p>${loginReasons[params.get("why")] ? `<p class="notice" data-testid="login-reason">${E(loginReasons[params.get("why")])}</p>` : ""}${/KAKAOTALK|NAVER|Instagram|FBAN|FBAV|Line\/|Telegram|; wv\)/i.test(navigator.userAgent) ? '<p class="hint" style="color:#b4235a;margin:10px 0">카카오톡·텔레그램 등 앱 안에서는 Google 로그인이 막힐 수 있어요. 오른쪽 위 메뉴에서 <b>다른 브라우저로 열기</b>(크롬·사파리)를 눌러 주세요. 이메일 로그인은 여기서도 됩니다.</p>' : ""}${btn("Google로 계속하기", "google", `data-testid="google-login" ${window.BL_CONFIG?.googleReady === false ? 'disabled aria-disabled="true"' : ""}`, true)}<p class="hint" style="margin-top:10px">${window.BL_CONFIG?.googleReady === false ? "Google 로그인 연결 준비 중입니다. 아래 이메일로 계속해 주세요." : "이메일 발송 한도 없이 로그인할 수 있는 Google 로그인을 권장합니다."}</p><div class="separator">또는 이메일로 로그인</div><form data-form="email" id="email-form">${field("email", "이메일 주소", "email", "", 'required autocomplete="email" placeholder="name@example.com" data-testid="login-email"')}${formEnd("로그인 메일 받기")}</form><div id="otp-area" hidden><form data-form="otp"><h2 style="margin-top:24px">인증번호로 확인</h2><p class="small muted">메일에 인증번호가 있다면 입력해 주세요. 로그인 링크로도 접속할 수 있습니다.</p>${field("token", "이메일 인증번호", "text", "", 'required inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6,10}"')}${formEnd("인증번호 확인")}</form></div><p class="hint" style="margin-top:20px">${window.BL_CONFIG?.customSMTP === false ? "이메일 로그인은 현재 사전 등록된 운영자 이메일만 지원하며 서비스 전체 시간당 2건으로 제한됩니다. 일반 가입을 위한 메일 연결을 준비하고 있습니다." : window.BL_CONFIG?.emailRateLimit ? `로그인 메일은 서비스 전체 시간당 ${Number(window.BL_CONFIG.emailRateLimit)}건 한도가 적용됩니다. 잠시 기다린 뒤 다시 요청해 주세요.` : "이메일 발송에는 한도가 적용됩니다. 기본 발송기는 시간당 2건이며 허용된 주소만 지원합니다. 별도 메일 서버 연결 시 한도가 달라질 수 있습니다."}</p><p class="small muted">이용 전 <a class="text-link" href="/terms.html">이용약관</a>과 <a class="text-link" href="/privacy.html">개인정보처리방침</a>을 확인해 주세요. 로그인만으로 회사 인증이 완료되지는 않습니다.</p></section>`;
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
    if (tab === "posts") body = feeds(d.posts);
    else if (tab === "bookmarks") body = feeds(d.bookmarks);
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
      return `<section class="explore"><h1>보험사·GA 리뷰</h1><p class="muted">현재 소속이 인증된 동료들의 경험을 모읍니다. 5개 이상의 리뷰가 쌓이면 평균 별점을 공개합니다.</p><div class="channel-cards">${companies.map((c) => `<a class="channel-card" href="${uri("company.html", { id: c.id })}"><span class="company-mark">${E(c.name)}</span><div class="channel-card-info"><h2>${E(c.name)}</h2><p>${E(c.kind || "보험사")}</p><span class="small">${c.average != null ? `<span class="stars">★</span> ${Number(c.average).toFixed(1)}` : "리뷰 모으는 중"} · 리뷰 ${Number(c.review_count) || 0}개</span></div></a>`).join("")}</div>${companies.length ? "" : empty("등록된 회사가 없어요.", "운영자가 회사 목록을 준비하고 있습니다.")}</section>`;
    const d = await read("company", { id });
    current = d;
    const c = d.company;
    if (!c) return empty("회사 정보를 찾을 수 없어요.", "보험사·GA 목록에서 다시 선택해 주세요.");
    const canReview = c.enabled !== false && (isOwner() || (isVerified() && mine?.profile?.company_id === id));
    return `<div class="company-cover"></div><section class="company-hero"><a class="back-link" href="/company.html">← 보험사·GA 목록</a><div class="section-head"><h1>${E(c.name)}</h1><span class="company-mark">${E(c.kind || "보험사")}</span></div><p class="muted">${E(c.description || "설계사 동료가 나누는 근무 경험입니다.")}</p><div class="metrics"><div><strong>${Number(c.review_count) || 0}개</strong>리뷰</div><div><strong>${c.average != null ? Number(c.average).toFixed(1) : "모으는 중"}</strong>종합 별점</div><div><strong>5항목</strong>설계사 관점</div><div><strong>1년 1건</strong>회사별 작성</div></div>${c.average != null ? `<div class="rating-grid">${scoreNames.map((s, i) => `<div class="review-score"><span>${s}</span><span>${Number(c.scores?.[i] || 0).toFixed(1)} / 5</span></div>`).join("")}</div>` : '<p class="notice">유효한 리뷰가 5개 이상 모이면 전체·항목별 평균 별점을 공개합니다.</p>'}<p></p>${canReview ? btn("리뷰 작성", "review-new", `data-id="${E(c.id)}" data-testid="review-create"`, true) : isOwner() ? '<p class="hint">숨김 처리된 회사입니다. 관리자에서 회사를 공개한 후 리뷰를 작성할 수 있어요.</p>' : `<p class="hint">현재 소속 회사가 인증된 회원만 리뷰를 작성할 수 있어요.</p>${viewer?.status === "suspended" ? '<a class="btn" href="/help.html">이용 정지 안내</a>' : session ? '<a class="btn" href="/verify.html">내 소속 인증하기</a>' : verifyLink("btn")}`}</section><nav class="company-tabs"><a class="active" href="#company-reviews">리뷰</a><a href="#company-posts">관련 글</a></nav><section id="company-reviews">${d.reviews?.length ? d.reviews.map(reviewHTML).join("") : empty("아직 등록된 리뷰가 없어요.", "현재 소속 회사에 대한 첫 경험을 남겨 주세요.")}</section><section id="company-posts"><h2 class="section">${E(c.name)} 관련 글</h2>${feeds(d.posts, true)}</section>`;
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
  const companyKinds = ["보험사", "GA"];
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
    audit: (a) =>
      `<div class="admin-row static" data-testid="audit-row"><span class="row-main"><strong>${E(a.actor_name || (a.detail?.by === "자동 판정" ? "자동 판정" : "시스템"))}</strong> · ${E(auditName(a.action))}${a.target ? ` · ${E(targetNames[a.target] || a.target)}` : ""}</span><span class="row-sub">${E(date(a.created_at))}${a.detail?.reason ? ` · 사유: ${E(a.detail.reason)}` : ""}${a.detail?.decision ? ` · ${E(autoNames[a.detail.decision] || a.detail.decision)}` : ""}${a.detail?.status && !a.detail?.decision && auditStatus(a.detail.status) ? ` · ${E(auditStatus(a.detail.status))}` : ""} · 기록 ${E(a.id)}</span></div>`,
  };

  const adminRender = {
    dashboard(d) {
      const k = d.dashboard || {},
        t = d.todo || {};
      const todoTotal = (Number(t.verifications) || 0) + (Number(t.reports) || 0) + (Number(t.ai_review) || 0);
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
      return `<section class="admin-todo ${todoTotal ? "has-todo" : ""}" data-testid="admin-todo"><h3>처리할 일 ${todoTotal}건</h3>${todoTotal ? `<div class="todo-links"><a href="/admin/?section=verifications&amp;status=pending">인증 심사 대기 ${Number(t.verifications) || 0}건${t.verifications_hold ? ` (자동 판정 보류 ${Number(t.verifications_hold)}건)` : ""}</a><a href="/admin/?section=reports">미처리 신고 ${Number(t.reports) || 0}건</a><a href="/admin/?section=ai">AI 답변 검토 ${Number(t.ai_review) || 0}건</a></div>` : '<p class="muted small">지금 처리할 일이 없어요.</p>'}</section><div class="status-list">${labels.map(([key, label]) => `<div><strong>${Number(k[key]) || 0}</strong><small>${label}</small></div>`).join("")}</div><p class="notice small" data-testid="dashboard-count-basis">집계 기준: 시험 계정·임시 견본은 빼고 셉니다. ${Number(k.expiring) ? `<a href="/admin/?section=members&amp;status=expiring">인증 만료 예정자 보기 →</a>` : ""}</p><section class="trend" aria-label="최근 14일 추이"><h3>최근 14일 가입·글·댓글</h3><div class="trend-legend"><span class="tm">가입</span><span class="tp">글</span><span class="tc">댓글</span></div><div class="trend-bars">${trend.map((x) => `<div class="trend-day" title="${E(x.day)} 가입 ${Number(x.members) || 0} · 글 ${Number(x.posts) || 0} · 댓글 ${Number(x.comments) || 0}"><div class="trend-stack">${bar(x.members, "tm")}${bar(x.posts, "tp")}${bar(x.comments, "tc")}</div><small>${E(String(x.day).slice(3))}</small></div>`).join("")}</div></section>`;
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
    const tabCount = { verifications: Number(t.verifications) || 0, reports: Number(t.reports) || 0, ai: Number(t.ai_review) || 0 };
    return `<section class="section admin-page"><div class="section-head"><h1>관리자 모드</h1><span class="status-badge">${isOwner() ? "대표 관리자 · 모든 권한" : "관리자"}</span></div><nav class="admin-tabs" aria-label="관리 메뉴">${adminSections.map(([id, label]) => `<a class="chip ${section === id ? "active" : ""}" href="${uri("admin/", { section: id })}">${label}${tabCount[id] ? ` <span class="tab-count">${tabCount[id]}</span>` : ""}</a>`).join("")}</nav><h2>${E(adminSections.find(([s]) => s === section)?.[1] || "대시보드")}</h2>${adminRender[sec](d)}</section>`;
  }
  const policyDocs = {
    terms: `<h1>이용약관</h1><p class="document-meta">시행일: 2026년 11월 7일 · 보험라이브</p><h2>1. 서비스와 가입</h2><p>보험라이브는 보험설계사들이 실무 지식과 개인 경험을 나누는 커뮤니티입니다. 성인 이용자는 Google 또는 이메일로 로그인할 수 있습니다. 설계사 인증을 마쳐야 회원 전용 글·댓글·AI 답변을 읽고 글을 작성할 수 있습니다. 가입 정보와 증빙은 본인의 현재 정보여야 합니다.</p><h2>2. 공개 범위</h2><p>공개 화면에는 소속 회사명과 닉네임 첫 글자 뒤 별표 3개만 표시합니다. 완전익명 채널의 글·댓글은 회사명·닉네임 없이 ‘익명’으로만 표시하며, 운영자는 신고 처리 등 필요한 경우에만 사유를 기록하고 작성자를 확인합니다. 실무지식·커리어·운영팀 정리는 본문 전체, 경험·자유 글과 회사 리뷰는 앞부분 최대 300자를 공개합니다. 댓글·대댓글·AI 답변은 인증 회원에게만 제공됩니다. 본문 자체에 개인정보를 쓰면 작성자를 추정할 수 있으므로 게시 전에 확인해 주세요.</p><h2>3. 회원 콘텐츠와 책임</h2><p>게시물의 권리는 작성자에게 있습니다. 작성자는 서비스 안에서 콘텐츠를 저장·표시하고 신고를 처리하는 데 필요한 이용을 허락합니다. 회원의 글과 리뷰는 개인 의견이며 소속 회사나 운영팀의 공식 입장, 보험상품 가입 권유 또는 개별 계약에 대한 확정적인 판단이 아닙니다. 실제 계약·보장·지급 여부는 약관과 공식 자료로 확인해야 합니다.</p><h2>4. 금지 행위와 운영 조치</h2><p>허위사실·명예훼손·개인정보 공개·욕설·사칭·불법 자료·도배·무단 광고·계정 거래·악의적 신고·권한 우회는 금지합니다. 운영자는 사유를 기록하고 글 숨김·삭제, 인증 보완·반려, 일시 또는 지속적 이용 제한을 적용할 수 있습니다. 주요 결과는 서비스 내 알림과 내 정보에 안내합니다.</p><h2>5. 권리침해 신고와 임시조치</h2><p>사생활 침해·명예훼손 등 권리침해를 주장하는 회원은 글·댓글·리뷰의 신고 메뉴에서 대상과 침해 사실을 구체적으로 소명해 삭제 또는 조치를 요청할 수 있습니다. 신고는 설계사 인증을 마친 회원이 할 수 있으며 본인의 글은 신고할 수 없습니다. 같은 콘텐츠에 서로 다른 회원의 신고가 3건 이상 모이거나 운영자가 필요하다고 판단하면 접근을 임시 차단하고 신청인·게시자에게 서비스 내 알림으로 알리며 원래 게시물 위치에 조치 사실을 표시합니다. 운영 공지는 신고로 자동 가려지지 않고 운영자가 직접 검토합니다. 권리침해 판단이 어렵거나 다툼이 예상될 때 정보통신망법 제44조의2에 따른 임시조치는 30일 이내로 합니다. 운영자는 그 안에 소명을 검토해 복구 또는 위반에 따른 최종 가림·삭제를 결정합니다. 미결인 임시조치는 기간 종료 후 복구하고 당사자에게 알립니다. 조치 사유가 잘못되었다고 판단하면 해당 신고에 추가 소명을 적어 이의를 제기할 수 있습니다.</p><h2>6. 회사 리뷰와 AI</h2><p>회사 리뷰는 현재 소속이 인증된 회원이 회사별 365일에 1건 작성할 수 있으며 본인의 리뷰를 수정할 수 있습니다. 5개 이상의 유효 리뷰가 모이면 평균을 공개합니다. AI 참고 답변은 AI 작성 표시를 하며 정확성을 보장하지 않습니다. 사람 댓글과 인기 수치에 포함하지 않고 운영 검토와 설정에 따라 표시합니다.</p><h2>7. 탈퇴와 변경</h2><p>내 정보에서 탈퇴하면 회원 전용 접근을 즉시 차단하고 남은 콘텐츠의 작성자를 ‘탈퇴한 회원’으로 표시합니다. 삭제를 원하는 본인 글·댓글은 탈퇴 전에 삭제해 주세요. 관계 법령상 보관 의무가 없는 인증 정보는 삭제합니다. 약관 변경과 중요한 운영 변경은 공지로 안내합니다.</p>`,
    privacy: `<h1>개인정보처리방침</h1><p class="document-meta">시행일: 2026년 11월 7일 · 보험라이브 운영팀</p><h2>1. 수집하는 정보와 목적</h2><p>로그인에는 이메일 주소와 로그인 제공자가 발급하는 계정 식별정보를 사용합니다. 설계사 인증에는 이름, 닉네임, 현재 소속 회사, 연락처, 설계사 고유번호와 증빙 사진 1장을 받습니다. 목적은 계정 확인, 설계사·소속 심사, 부정 이용 방지, 회원 문의와 신고 처리입니다. 주민등록번호는 수집하지 않습니다. 증빙에 주민등록번호·주소·고객정보가 있으면 업로드 전에 가려 주세요.</p><h2>2. 공개 정보와 접근 권한</h2><p>공개 화면에 회사명과 닉네임 첫 글자·별표 3개만 표시합니다(완전익명 채널은 ‘익명’으로만 표시하고, 운영자의 작성자 확인은 사유와 함께 감사 기록에 남깁니다). 실명, 연락처, 설계사 고유번호, 증빙 사진은 공개하지 않습니다. 증빙은 비공개 저장소에 보관하고 담당 관리자만 60초 동안 유효한 서명 주소로 확인합니다. 제출한 증빙 사진은 운영팀 Mac의 기기 안 글자인식(Apple Vision)으로 이름·설계사 고유번호·소속 회사를 읽어 신청 내용과 자동으로 비교하며, 사진과 읽은 내용을 외부 AI나 다른 서비스로 보내지 않습니다. 자동 판정 결과(승인·반려·보류)는 운영자가 확인하고 바꿀 수 있습니다. 관리자의 열람과 처리 행동은 감사 기록으로 남깁니다. 공개 회원 명부나 회원별 공개 프로필을 제공하지 않습니다.</p><h2>3. 보유 기간과 파기</h2><p>계정과 공개 닉네임·현재 소속·인증 상태는 회원 유지 기간 동안 사용합니다. 인증 증빙과 심사 원본 개인정보는 승인·반려 등 처리 후 30일이 지나면 삭제 대상으로 지정하며 정리 작업에서 파일과 원본 정보를 제거합니다. 신청하지 않은 업로드 파일은 24시간 뒤 삭제 대상이 됩니다. 탈퇴 시 접근을 즉시 차단하고 개인정보와 증빙을 삭제 대상으로 전환합니다. 회원의 남은 글·댓글은 신원과의 공개 연결을 끊고 ‘탈퇴한 회원’으로 표시합니다. 법적 보존 의무가 발생한 정보는 법령이 정한 범위와 기간에 한해 별도로 보관합니다.</p><h2>4. 처리에 사용하는 서비스</h2><p>웹 화면은 GitHub Pages, 계정 인증·데이터베이스·비공개 파일 저장은 Supabase를 사용합니다. Google 로그인 선택 시 Google의 계정 확인 절차를 거칩니다. 이메일 로그인 시 로그인 확인 메일 발송에만 이메일 주소를 사용합니다. 서비스 제공자의 처리 설비가 해외에 있을 수 있으며 처리 위치와 제공자 정책은 각 서비스의 공개 정책에 따릅니다. 광고 추적, 외부 광고 이미지, 제3자 분석 스크립트를 넣지 않습니다.</p><h2>5. AI 참고 답변</h2><p>질문형 글을 선택한 경우 게시물의 제목과 본문을 Mac 처리기에서 기존 구독의 AI 도구로 처리할 수 있습니다. 회원의 실명·연락처·증빙을 답변 생성 입력에 포함하지 않습니다. 질문에도 고객 개인정보나 민감한 계약자료를 적지 마세요.</p><h2>6. 이용자의 권리와 문의</h2><p>내 정보에서 현재 상태, 내 글·댓글·북마크·알림을 확인하고 닉네임을 변경할 수 있습니다. 소속 변경은 새 증빙과 함께 재인증을 신청해 주세요. 탈퇴는 내 정보의 회원 탈퇴로 직접 처리할 수 있습니다. 개인정보가 포함된 글·댓글은 해당 콘텐츠의 신고 메뉴에서 구체적인 대상과 삭제 요청 사유를 남길 수 있습니다. 운영자는 이를 확인해 접근 제한·정정·삭제를 처리합니다.</p><h2>7. 보호 조치와 로그인 유지</h2><p>데이터베이스에서 회원 상태와 역할을 검사해 공개·회원·관리자 정보를 분리하고, 전송 구간은 HTTPS를 사용합니다. 로그인 유지를 위해 브라우저 저장소에 인증 세션을 보관합니다. 공용 기기에서는 사용 후 로그아웃해 주세요. 정지·탈퇴·세션 만료 시 서버가 회원 전용 요청을 거부하며 화면도 상태를 다시 확인합니다.</p>`,
    rules: `<h1>커뮤니티 운영정책</h1><p class="document-meta">시행일: 2026년 11월 7일</p><h2>경험은 솔직하게, 사람은 존중해 주세요</h2><p>직접 겪은 사실과 의견을 구분하고 자료의 기준일을 함께 적어 주세요. 타인·회사에 대한 허위사실, 명예훼손, 위협, 혐오와 비방은 허용하지 않습니다. 리뷰와 회원 글은 작성자 개인 의견입니다.</p><h2>영업화법은 정직하게</h2><p>허위·과장·부당권유 화법, 고객정보·녹취 게시는 금지합니다.</p><h2>개인정보와 고객자료를 올리지 마세요</h2><p>본인이나 타인의 실명·연락처·주소·주민등록번호·계약번호·질병정보·고객 사진, 개인을 추정할 수 있는 조합 정보를 공개하지 마세요. 회사 이름은 실제 명칭으로 표시하지만 지점·직급·담당 고객 등 개인을 특정하는 상세정보는 게시하지 않습니다.</p><h2>반복 게시와 영업을 제한합니다</h2><p>인증 회원은 글 하루 10개, 글 사이 60초, 댓글 하루 50개, 댓글 사이 10초 간격을 지켜야 합니다. 서버에서 제한을 적용합니다. 같은 내용 반복, 무단 광고·모집·판매, 계정 거래, 자동화 도배, 악의적 신고는 제재 대상입니다. 신고도 회원당 하루 10건으로 제한합니다.</p><h2>신고 → 운영자 판단(필요하면 임시 가림)</h2><p>설계사 인증 회원은 각 글·댓글·리뷰에서 신고 사유를 선택하고 대상과 침해 사실을 구체적으로 적어 신고할 수 있습니다(내 글은 신고할 수 없음). 같은 콘텐츠에 서로 다른 회원의 신고가 3건 이상 모이면 운영자 판단 전까지 임시로 가리고 신고자와 작성자에게 알립니다. 운영 공지는 신고로 자동 가려지지 않습니다. 운영자는 사실관계·소명을 확인해 복구하거나 위반이 확인된 경우 가림을 유지·삭제합니다. 권리침해 다툼을 위한 임시조치는 최대 30일이며 미결 건은 기간 종료 후 복구합니다. 신고 자체가 위반 확정을 뜻하지 않습니다.</p><h2>처리 결과와 이의신청</h2><p>콘텐츠 숨김·삭제, 인증 보완·반려, 일시 정지 또는 반복 위반 계정 정지를 적용할 수 있습니다. 사유는 내 정보와 알림에 표시합니다. 이의가 있으면 해당 대상의 신고 메뉴에서 ‘처리 결과 이의신청’을 선택하고 기존 조치와 추가 소명을 적어 주세요. 운영자는 검토 사유와 결과를 기록합니다.</p><h2>AI와 회사 리뷰</h2><p>AI 참고 답변은 사람의 답변과 구분하여 표시하며 전문적인 확정 판단으로 사용하지 마세요. 현재 인증된 회사의 리뷰만 작성할 수 있고, 실제 근무 경험 없이 평가하거나 리뷰를 거래·조작하는 행위를 금지합니다.</p>`,
    help: `<h1>이용 도움말</h1><h2>이용하는 순서</h2><ol><li>Google 또는 이메일로 로그인합니다.</li><li>설계사 인증에서 이름·소속·연락처·설계사 고유번호와 증빙 사진 1장을 제출합니다.</li><li>내 정보와 알림에서 심사 결과를 확인합니다.</li><li>인증 후 글·댓글·북마크·리뷰를 이용합니다.</li></ol><h2>공개 표시</h2><p>예를 들어 닉네임 ‘바른설계’이고 소속이 삼성생명이면 ‘삼성생명 · 바***’로 보입니다. ‘완전익명’ 채널에서는 회사명·닉네임 없이 ‘익명’으로 보여요. 소속 변경 시 재인증을 신청해야 합니다.</p><h2>권리침해 신고와 이의신청</h2><p>설계사 인증 회원은 글·댓글·리뷰의 신고 버튼에서 대상, 사유와 침해 사실을 적어 신고할 수 있어요. 주민등록번호나 불필요한 개인 정보는 기재하지 마세요. 운영자가 검토해 서비스 내 알림으로 결과를 안내하며, 같은 콘텐츠에 신고가 3건 이상 모이면 검토 전까지 임시로 가립니다. 이미 조치된 글의 공개 주소를 알고 있다면 아래에서 대상 번호와 소명을 입력할 수 있습니다.</p><form data-form="report"><div class="form-grid">${select(
      "target",
      "대상 종류",
      [
        ["post", "글"],
        ["comment", "댓글"],
        ["review", "리뷰"],
      ],
    )}${field("id", "대상 번호 (주소의 id 값)", "text", "", 'required pattern="[0-9a-fA-F-]{36}"')}</div>${select(
      "reason_type",
      "신고 종류",
      [
        ["privacy", "개인정보 노출"],
        ["defamation", "명예훼손·허위사실"],
        ["appeal", "처리 결과 이의신청"],
        ["other", "그 밖의 권리침해"],
      ],
    )}${area("reason_detail", "침해 사실과 소명", "", 'required minlength="5" maxlength="2000" placeholder="침해당한 권리, 대상 내용과 요청하는 조치를 구체적으로 적어 주세요."')}${formEnd("신고·소명 접수")}</form><h2>로그인 메일이 오지 않아요</h2><p>스팸함과 이메일 주소를 확인해 주세요. 발송 한도가 적용되므로 연속 요청을 피하고 잠시 뒤 다시 시도해 주세요. Google 로그인 연결이 완료되어 있으면 Google로 계속할 수 있습니다.</p><h2>계정을 정리하고 싶어요</h2><p>내 정보에서 본인이 쓴 글·댓글을 확인하고 삭제한 뒤 탈퇴할 수 있습니다. 탈퇴 즉시 회원 전용 내용에 접근할 수 없고, 남겨둔 글은 ‘탈퇴한 회원’으로 보입니다.</p>`,
  };
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
      if (policyDocs[page]) html = `<article class="section policy">${policyDocs[page]}</article>`;
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
      updatePreview();
      updateDisplay();
    } catch (err) {
      if (stamp !== renderId) return;
      layout();
      $("#content").innerHTML =
        `<section class="section"><h1>잠시 연결을 확인해 주세요</h1><p class="error" role="alert">${E(safeError(err))}</p>${btn("다시 시도", "refresh", "", true)} <a class="btn" href="/index.html">홈으로</a></section>`;
    }
  }
  async function requireWriting(why = "") {
    if (session) mine = await read("me");
    if (isVerified()) return true;
    closeDialog();
    if (!session) {
      location.href = loginUrl(here(), why);
      return false;
    }
    await refresh();
    notify(
      viewer?.status === "suspended"
        ? "이용 정지 상태에서는 작성할 수 없어요. 내 정보의 운영 안내를 확인해 주세요."
        : "설계사 인증을 완료한 뒤 작성할 수 있어요. 인증 신청·보완을 확인해 주세요.",
    );
    return false;
  }
  async function clickAction(el, event) {
    const action = el.dataset.do,
      id = el.dataset.id;
    if (
      [
        "toggle",
        "reply",
        "comment-edit",
        "review-new",
        "review-edit",
        "post-delete",
        "comment-delete",
        "review-delete",
      ].includes(action) &&
      !(await requireWriting(action === "toggle" ? el.dataset.kind : ""))
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
      case "toggle":
        await act("toggle", { target: el.dataset.target, id, kind: el.dataset.kind });
        return refresh();
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
        slot.innerHTML = `<form data-form="comment" class="inline-form"><input type="hidden" name="post_id" value="${E(current.post.id)}"><input type="hidden" name="parent_id" value="${E(id)}">${area("reply-body", "답글", "", 'required maxlength="3000"')}${formEnd("답글 등록")}</form>`;
        slot.querySelector("textarea").focus();
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
        await act("comment_save", payload);
        closeDialog();
        notify(v.id ? "댓글을 수정했어요." : "댓글을 등록했어요.");
        return refresh();
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
        else {
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
