import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outSvg = path.join(__dirname, "cards-svg");
const outPng = path.join(__dirname, "cards-png");
const previewPath = path.join(__dirname, "preview.html");
const contactSheetPath = path.join(__dirname, "contact-sheet.png");
const W = 900;
const H = 1200;

function loadSharp() {
  const require = createRequire(import.meta.url);
  const candidates = [
    "sharp",
    process.env.CODEX_NODE_MODULES
      ? path.join(process.env.CODEX_NODE_MODULES, "sharp")
      : "",
    path.join(
      process.env.HOME || "",
      ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp"
    )
  ].filter(Boolean);

  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch {
      // Try the next known runtime location.
    }
  }

  throw new Error("Cannot load sharp. Set CODEX_NODE_MODULES to a node_modules folder containing sharp.");
}

const sharp = loadSharp();

const font = `-apple-system, BlinkMacSystemFont, PingFang SC, Hiragino Sans GB, Noto Sans CJK SC, sans-serif`;
const mono = `SFMono-Regular, Menlo, Consolas, monospace`;

const cards = [
  {
    id: "01-cover",
    label: "Codex 工作流",
    title: ["别再盯着", "Codex 终端了"],
    subtitle: "红灯要你处理，黄灯正在跑，绿灯可以验收",
    note: "一个 macOS 菜单栏 + 悬浮交通灯小工具",
    state: "waiting"
  },
  {
    id: "02-pain",
    label: "真实痛点",
    title: ["Codex 跑着跑着", "我总想切回去看"],
    subtitle: "多任务、授权、等待回复、完成验收，全挤在终端里。",
    bullets: ["到底还在 working？", "是不是在等我授权？", "完成了要不要验收？"],
    state: "working"
  },
  {
    id: "03-solution",
    label: "解决方案",
    title: ["我给 Codex", "做了一个交通灯"],
    subtitle: "常驻菜单栏；红灯或绿灯时弹出悬浮提示。",
    bullets: ["不打断工作流", "不需要反复切窗口", "一眼知道下一步该不该介入"],
    state: "done"
  },
  {
    id: "04-states",
    label: "四种状态",
    title: ["红黄绿暗", "各管一件事"],
    subtitle: "状态足够简单，所以真的能一眼看懂。",
    mode: "states"
  },
  {
    id: "05-hooks",
    label: "自动联动",
    title: ["Hooks 不只变灯", "还能同步额度"],
    subtitle: "任务事件映射状态；额度事件只更新 quota，不会创建任务。",
    bullets: ["PermissionRequest 变红灯", "Stop / SubagentStop 变绿灯", "quota 事件只更新额度"],
    state: "working",
    terminal: true
  },
  {
    id: "06-advanced",
    label: "额度 HUD",
    title: ["额度也能", "自动显示"],
    subtitle: "通过 Codex app-server 读取周剩余额度。",
    bullets: ["多任务聚合：waiting > working > done > idle", "声音提醒：红灯/绿灯有不同提示音", "CLI 控制：status、clear、quota 都能手动调"],
    state: "waiting",
    quota: true
  },
  {
    id: "07-cta",
    label: "开源小工具",
    title: ["适合 Codex", "重度用户"],
    subtitle: "如果你也经常让 Codex 跑任务，这个小灯会很省心。",
    note: "GitHub 地址放评论/主页",
    state: "idle"
  }
];

const colors = {
  ink: "#151515",
  muted: "#5d6470",
  paper: "#fffdf7",
  red: "#ff4b4b",
  yellow: "#ffd33d",
  green: "#35c96f",
  dark: "#34373d",
  blue: "#3178ff",
  line: "#e8e1d7"
};

function esc(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function textLines(lines, x, y, opts = {}) {
  const {
    size = 48,
    weight = 700,
    fill = colors.ink,
    lineHeight = Math.round(size * 1.18),
    family = font,
    anchor = "start",
    letterSpacing = 0
  } = opts;
  return `
    <text x="${x}" y="${y}" font-family="${family}" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}" letter-spacing="${letterSpacing}">
      ${lines
        .map((line, index) => `<tspan x="${x}" dy="${index === 0 ? 0 : lineHeight}">${esc(line)}</tspan>`)
        .join("")}
    </text>
  `;
}

function pill(x, y, text, fill = "#ffffff", stroke = colors.line, textFill = colors.ink) {
  const width = Math.max(124, text.length * 18 + 42);
  return `
    <rect x="${x}" y="${y}" width="${width}" height="44" rx="22" fill="${fill}" stroke="${stroke}"/>
    <text x="${x + 22}" y="${y + 29}" font-family="${font}" font-size="18" font-weight="800" fill="${textFill}">${esc(text)}</text>
  `;
}

function macBar(y = 58) {
  return `
    <g filter="url(#softShadow)">
      <rect x="70" y="${y}" width="760" height="54" rx="24" fill="rgba(255,255,255,0.88)" stroke="#eee7dd"/>
      <circle cx="112" cy="${y + 27}" r="8" fill="${colors.red}"/>
      <circle cx="138" cy="${y + 27}" r="8" fill="${colors.yellow}"/>
      <circle cx="164" cy="${y + 27}" r="8" fill="${colors.green}"/>
      <text x="204" y="${y + 34}" font-family="${font}" font-size="19" font-weight="800" fill="${colors.ink}">Codex Traffic Light MXP</text>
      <g transform="translate(678 ${y + 17})">
        <circle cx="0" cy="10" r="8" fill="${colors.red}"/>
        <circle cx="26" cy="10" r="8" fill="${colors.yellow}"/>
        <circle cx="52" cy="10" r="8" fill="${colors.green}"/>
        <text x="78" y="17" font-family="${font}" font-size="16" font-weight="700" fill="${colors.muted}">waiting</text>
      </g>
    </g>
  `;
}

function trafficLight(x, y, state = "waiting", scale = 1) {
  const active = {
    waiting: [true, false, false, false],
    working: [false, true, false, false],
    done: [false, false, true, false],
    idle: [false, false, false, true]
  }[state] || [false, false, false, true];
  const lights = [
    [colors.red, "waiting"],
    [colors.yellow, "working"],
    [colors.green, "done"],
    [colors.dark, "idle"]
  ];
  const gap = 86;
  return `
    <g transform="translate(${x} ${y}) scale(${scale})">
      <rect x="-34" y="-34" width="404" height="128" rx="44" fill="#ffffff" stroke="#ece2d6" filter="url(#softShadow)"/>
      ${lights
        .map(([color, label], index) => {
          const cx = index * gap + 26;
          const opacity = active[index] ? 1 : 0.23;
          const glow = active[index] ? `filter="url(#glow)"` : "";
          return `
            <g>
              <circle cx="${cx}" cy="30" r="30" fill="${color}" opacity="${opacity}" ${glow}/>
              <text x="${cx}" y="78" text-anchor="middle" font-family="${mono}" font-size="13" font-weight="700" fill="${colors.muted}">${label}</text>
            </g>
          `;
        })
        .join("")}
    </g>
  `;
}

function floatingWindow(x, y, state) {
  const status = {
    waiting: ["需要你处理", colors.red, "PermissionRequest"],
    working: ["正在执行", colors.yellow, "PreToolUse"],
    done: ["可以验收", colors.green, "Stop"],
    idle: ["当前空闲", colors.dark, "idle"]
  }[state] || ["当前空闲", colors.dark, "idle"];
  return `
    <g transform="translate(${x} ${y})" filter="url(#softShadow)">
      <rect width="430" height="290" rx="34" fill="#ffffff" stroke="#ebe2d6"/>
      <text x="38" y="54" font-family="${font}" font-size="22" font-weight="900" fill="${colors.ink}">悬浮交通灯</text>
      <text x="38" y="86" font-family="${font}" font-size="16" font-weight="600" fill="${colors.muted}">Codex 当前状态</text>
      <circle cx="98" cy="164" r="52" fill="${status[1]}" filter="url(#glow)"/>
      <text x="178" y="150" font-family="${font}" font-size="34" font-weight="900" fill="${colors.ink}">${status[0]}</text>
      <text x="180" y="186" font-family="${mono}" font-size="18" font-weight="700" fill="${colors.muted}">${status[2]}</text>
      <rect x="38" y="232" width="354" height="18" rx="9" fill="#f0f2f5"/>
      <rect x="38" y="232" width="170" height="18" rx="9" fill="${colors.green}"/>
      <text x="38" y="268" font-family="${font}" font-size="15" font-weight="700" fill="${colors.muted}">周额度 48%</text>
    </g>
  `;
}

function bulletList(items, x, y) {
  return items
    .map((item, index) => {
      const cy = y + index * 66;
      return `
        <g>
          <circle cx="${x}" cy="${cy - 8}" r="12" fill="${index === 0 ? colors.red : index === 1 ? colors.yellow : colors.green}"/>
          <text x="${x + 32}" y="${cy}" font-family="${font}" font-size="28" font-weight="800" fill="${colors.ink}">${esc(item)}</text>
        </g>
      `;
    })
    .join("");
}

function statusGrid() {
  const items = [
    ["红灯", "waiting", "需要你回复、确认或授权", colors.red],
    ["黄灯", "working", "Codex 正在执行任务", colors.yellow],
    ["绿灯", "done", "任务已完成，可以验收", colors.green],
    ["暗灯", "idle", "没有活跃任务", colors.dark]
  ];
  return `
    <g transform="translate(78 650)">
      ${items
        .map(([name, code, desc, color], index) => {
          const row = Math.floor(index / 2);
          const col = index % 2;
          const x = col * 372;
          const y = row * 210;
          return `
            <g transform="translate(${x} ${y})" filter="url(#smallShadow)">
              <rect width="336" height="174" rx="28" fill="#ffffff" stroke="#ece3d8"/>
              <circle cx="58" cy="58" r="26" fill="${color}" ${index !== 3 ? 'filter="url(#glow)"' : ""}/>
              <text x="104" y="54" font-family="${font}" font-size="30" font-weight="900" fill="${colors.ink}">${name}</text>
              <text x="104" y="84" font-family="${mono}" font-size="18" font-weight="800" fill="${colors.muted}">${code}</text>
              <text x="34" y="132" font-family="${font}" font-size="20" font-weight="700" fill="${colors.muted}">${desc}</text>
            </g>
          `;
        })
        .join("")}
    </g>
  `;
}

function terminalBlock(x, y) {
  return `
    <g transform="translate(${x} ${y})" filter="url(#softShadow)">
      <rect width="600" height="214" rx="24" fill="#131417"/>
      <circle cx="34" cy="32" r="8" fill="${colors.red}"/>
      <circle cx="60" cy="32" r="8" fill="${colors.yellow}"/>
      <circle cx="86" cy="32" r="8" fill="${colors.green}"/>
      <text x="34" y="82" font-family="${mono}" font-size="22" font-weight="700" fill="#f6f7f8">$ codex-light-mxp status</text>
      <text x="34" y="124" font-family="${mono}" font-size="21" font-weight="700" fill="${colors.yellow}">aggregate_state: working</text>
      <text x="34" y="164" font-family="${mono}" font-size="21" font-weight="700" fill="${colors.red}">hook_event_name: PermissionRequest</text>
    </g>
  `;
}

function featureTiles(items, x, y) {
  return items
    .map((item, index) => {
      const col = index % 2;
      const row = Math.floor(index / 2);
      const tx = x + col * 360;
      const ty = y + row * 158;
      const accents = [colors.red, colors.yellow, colors.green, colors.blue];
      return `
        <g transform="translate(${tx} ${ty})" filter="url(#smallShadow)">
          <rect width="320" height="120" rx="26" fill="#ffffff" stroke="#ebe2d6"/>
          <rect x="24" y="26" width="10" height="68" rx="5" fill="${accents[index]}"/>
          <text x="52" y="58" font-family="${font}" font-size="24" font-weight="900" fill="${colors.ink}">${esc(item[0])}</text>
          <text x="52" y="88" font-family="${font}" font-size="18" font-weight="700" fill="${colors.muted}">${esc(item[1])}</text>
        </g>
      `;
    })
    .join("");
}

function baseDefs() {
  return `
    <defs>
      <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#fff8d6"/>
        <stop offset="0.48" stop-color="#fffdf7"/>
        <stop offset="1" stop-color="#ecfff0"/>
      </linearGradient>
      <linearGradient id="panel" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#ffffff"/>
        <stop offset="1" stop-color="#f8fbff"/>
      </linearGradient>
      <filter id="softShadow" x="-20%" y="-20%" width="140%" height="150%">
        <feDropShadow dx="0" dy="18" stdDeviation="20" flood-color="#2f2618" flood-opacity="0.16"/>
      </filter>
      <filter id="smallShadow" x="-20%" y="-20%" width="140%" height="150%">
        <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#2f2618" flood-opacity="0.10"/>
      </filter>
      <filter id="glow" x="-80%" y="-80%" width="260%" height="260%">
        <feGaussianBlur stdDeviation="10" result="blur"/>
        <feMerge>
          <feMergeNode in="blur"/>
          <feMergeNode in="SourceGraphic"/>
        </feMerge>
      </filter>
    </defs>
  `;
}

function renderCard(card, index) {
  const titleY = index === 0 ? 286 : 292;
  const subtitleY = titleY + card.title.length * 82 + 36;
  const isCover = index === 0;
  const body = [
    `<rect width="${W}" height="${H}" fill="url(#bg)"/>`,
    `<path d="M0 1020 C190 955 322 1080 510 1008 C662 950 736 884 900 940 L900 1200 L0 1200 Z" fill="#ffffff" opacity="0.78"/>`,
    macBar(54),
    pill(78, isCover ? 180 : 158, card.label),
    textLines(card.title, 78, titleY, {
      size: isCover ? 80 : 68,
      weight: 950,
      lineHeight: isCover ? 94 : 82
    }),
    textLines([card.subtitle], 82, subtitleY, {
      size: isCover ? 31 : 28,
      weight: 800,
      fill: colors.muted,
      lineHeight: 38
    })
  ];

  if (card.mode === "states") {
    body.push(trafficLight(238, 536, "waiting", 1.04));
    body.push(statusGrid());
  } else if (index === 0) {
    body.push(trafficLight(96, 585, "waiting", 1.74));
    body.push(floatingWindow(236, 790, "waiting"));
    body.push(textLines([card.note], 82, 1110, { size: 25, weight: 800, fill: colors.muted }));
  } else if (card.terminal) {
    body.push(terminalBlock(78, 545));
    body.push(bulletList(card.bullets, 98, 840));
  } else if (card.quota) {
    body.push(floatingWindow(78, 512, "waiting"));
    body.push(featureTiles([
      ["app-server 采集", "读取 Codex 周额度"],
      ["60 秒轮询", "启动后自动刷新"],
      ["失败保留旧值", "不会突然清空成 --"],
      ["CLI 兜底", "app-server / stdin / 手动写"]
    ], 78, 845));
  } else if (index === 6) {
    body.push(trafficLight(108, 548, "idle", 1.56));
    body.push(`
      <g transform="translate(78 788)" filter="url(#softShadow)">
        <rect width="744" height="208" rx="34" fill="#ffffff" stroke="#ebe2d6"/>
        <text x="42" y="70" font-family="${font}" font-size="34" font-weight="950" fill="${colors.ink}">如果你也常开 Codex 跑任务</text>
        <text x="42" y="120" font-family="${font}" font-size="26" font-weight="800" fill="${colors.muted}">这个小灯会很省心。</text>
        <rect x="42" y="148" width="350" height="42" rx="21" fill="#151515"/>
        <text x="66" y="176" font-family="${font}" font-size="20" font-weight="900" fill="#ffffff">${esc(card.note)}</text>
      </g>
    `);
  } else {
    body.push(floatingWindow(78, 535, card.state));
    body.push(bulletList(card.bullets, 98, 890));
  }

  body.push(`
    <text x="78" y="1152" font-family="${mono}" font-size="18" font-weight="800" fill="${colors.muted}">${String(index + 1).padStart(2, "0")} / 07 · Codex Traffic Light MXP</text>
  `);

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  ${baseDefs()}
  <style>
    text { dominant-baseline: alphabetic; }
  </style>
  ${body.join("\n")}
</svg>
`;
}

function renderPreview() {
  const items = cards
    .map((card, index) => {
      const png = `cards-png/${card.id}.png`;
      return `
        <figure>
          <img src="${png}" alt="${esc(card.id)}" />
          <figcaption>${index + 1}. ${esc(card.title.join(" "))}</figcaption>
        </figure>
      `;
    })
    .join("\n");

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Codex Traffic Light MXP 小红书图文预览</title>
  <style>
    body {
      margin: 0;
      background: #f4f4f2;
      color: #151515;
      font-family: ${font};
    }
    main {
      max-width: 1220px;
      margin: 0 auto;
      padding: 48px 24px;
    }
    h1 {
      margin: 0 0 8px;
      font-size: 34px;
      line-height: 1.2;
    }
    p {
      margin: 0 0 28px;
      color: #666;
      font-size: 17px;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: 24px;
    }
    figure {
      margin: 0;
      background: white;
      border: 1px solid #e5e2dc;
      border-radius: 14px;
      padding: 12px;
      box-shadow: 0 14px 34px rgba(0,0,0,.08);
    }
    img {
      display: block;
      width: 100%;
      border-radius: 10px;
    }
    figcaption {
      padding: 10px 4px 2px;
      color: #555;
      font-size: 14px;
      font-weight: 700;
    }
  </style>
</head>
<body>
  <main>
    <h1>Codex Traffic Light MXP 小红书图文预览</h1>
    <p>7 页，900×1200，痛点直击方向。PNG 在 cards-png，SVG 源稿在 cards-svg。</p>
    <section class="grid">${items}</section>
  </main>
</body>
</html>
`;
}

await fs.mkdir(outSvg, { recursive: true });
await fs.mkdir(outPng, { recursive: true });

const generatedPngs = [];
for (const [index, card] of cards.entries()) {
  const svg = renderCard(card, index);
  const svgPath = path.join(outSvg, `${card.id}.svg`);
  const pngPath = path.join(outPng, `${card.id}.png`);
  await fs.writeFile(svgPath, svg, "utf8");
  await sharp(Buffer.from(svg)).png().toFile(pngPath);
  generatedPngs.push(pngPath);
}

const thumbW = 240;
const thumbH = 320;
const gap = 24;
const margin = 32;
const cols = 3;
const rows = Math.ceil(generatedPngs.length / cols);
const contactW = margin * 2 + cols * thumbW + (cols - 1) * gap;
const contactH = margin * 2 + rows * thumbH + (rows - 1) * gap;
const composites = [];

for (const [index, pngPath] of generatedPngs.entries()) {
  const input = await sharp(pngPath).resize(thumbW, thumbH).png().toBuffer();
  composites.push({
    input,
    left: margin + (index % cols) * (thumbW + gap),
    top: margin + Math.floor(index / cols) * (thumbH + gap)
  });
}

await sharp({
  create: {
    width: contactW,
    height: contactH,
    channels: 4,
    background: "#f4f4f2"
  }
})
  .composite(composites)
  .png()
  .toFile(contactSheetPath);

await fs.writeFile(previewPath, renderPreview(), "utf8");

console.log(`Generated ${cards.length} SVG files in ${outSvg}`);
console.log(`Generated ${cards.length} PNG files in ${outPng}`);
console.log(`Contact sheet: ${contactSheetPath}`);
console.log(`Preview: ${previewPath}`);
