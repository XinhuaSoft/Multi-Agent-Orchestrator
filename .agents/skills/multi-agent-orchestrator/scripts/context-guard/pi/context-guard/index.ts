/**
 * context-guard — pi extension
 *
 * コンテキスト使用量が閾値(既定 80%)を超えたら:
 *   1. Orca のコーディネーター(司令塔)に通知を送る(best-effort)
 *   2. エージェント自身に HANDOFF.md の更新と終了処理を指示する
 *
 * 環境変数:
 *   PI_CONTEXT_GUARD_THRESHOLD  発火閾値 0.0〜1.0(既定 0.8)
 *   PI_CONTEXT_GUARD_HANDOFF    HANDOFF ファイル名(既定 HANDOFF.md)
 *   PI_CONTEXT_GUARD_SILENT     "1" でコーディネーター通知を止める
 *
 * 配置:
 *   グローバル ~/.pi/agent/extensions/context-guard/index.ts
 *   プロジェクト <project>/.pi/extensions/context-guard/index.ts
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const THRESHOLD = clamp(Number(process.env.PI_CONTEXT_GUARD_THRESHOLD ?? "0.8"), 0.05, 1.0);
const HANDOFF_FILE = process.env.PI_CONTEXT_GUARD_HANDOFF ?? "HANDOFF.md";
const NOTIFY = process.env.PI_CONTEXT_GUARD_SILENT !== "1";

function clamp(v: number, lo: number, hi: number): number {
	if (Number.isNaN(v)) return 0.8;
	return Math.min(hi, Math.max(lo, v));
}

export default function (pi: ExtensionAPI) {
	// 同一セッションで繰り返し発火しないようにする
	let handoffRequested = false;
	let coordinatorNotified = false;

	async function notifyCoordinator(ctx: any, percent: number): Promise<void> {
		if (!NOTIFY || coordinatorNotified) return;
		coordinatorNotified = true;
		const cwd = ctx.sessionManager?.getCwd?.() ?? process.cwd();
		const body =
			`[context-guard] コンテキスト使用量が ${Math.round(percent * 100)}% に達しました。` +
			`このワーカーは HANDOFF.md を更新して終了報告を行います。` +
			`準備が整い次第、後任ワーカーの起動(worker-start --retry-of)を検討してください。` +
			`(cwd: ${cwd})`;
		try {
			// Orca ワーカーとして動いている場合のみ意味を持つ。
			// 非オーケストレーション環境では失敗するが無視してよい。
			await pi.exec("orca", ["orchestration", "ask", "--question", body], {
				timeout: 15000,
			});
		} catch {
			// orca CLI が無い / Orca 非稼働などは静かに諦める
		}
	}

	pi.on("agent_end", async (_event, ctx) => {
		let usage: { tokens: number | null; contextWindow: number; percent: number | null };
		try {
			usage = (ctx as any).getContextUsage?.();
		} catch {
			return;
		}
		if (!usage || usage.tokens == null || !usage.contextWindow) return;

		const percent = usage.percent ?? usage.tokens / usage.contextWindow;
		if (percent < THRESHOLD) return;

		await notifyCoordinator(ctx, percent);

		if (handoffRequested) return;
		handoffRequested = true;

		// エージェント自身に引き継ぎ処理をさせる(ユーザーメッセージとして注入)
		await pi.sendUserMessage(
			`[context-guard] コンテキスト使用量が ${Math.round(percent * 100)}% を超えました。` +
				`作業を続けず、今すぐ次の引き継ぎ処理を行ってください:\n` +
				`1. ${HANDOFF_FILE} に現状を整理して保存する` +
				`(完了したこと+証拠、進行中のこと、残タスク、重要な発見、次の一歩)\n` +
				`2. Orca ワーカーの場合は worker_done で終了報告する` +
				`(コーディネーターが後任を立てます)\n` +
				`3. それ以外の場合は報告して終了する。追加の作業はしないでください。`,
			{ deliverAs: "followUp" }
		);
	});

	// pi 自身の自動圧縮(threshold / overflow)が先に走った場合のフォローアップ:
	// 圧縮で文脈が要約に置き換わるので、ここでも HANDOFF 更新を促す
	pi.on("session_compact", async (event: any, ctx) => {
		if (handoffRequested) return;
		const reason = event?.reason ?? "threshold";
		if (reason !== "threshold" && reason !== "overflow") return;
		handoffRequested = true;
		await notifyCoordinator(ctx, 1.0);
		await pi.sendUserMessage(
			`[context-guard] コンテキストの自動圧縮(${reason})が発生しました。` +
				`圧縮で失われやすい情報を ${HANDOFF_FILE} に保存してください` +
				`(完了したこと+証拠、進行中のこと、残タスク、重要な発見、次の一歩)。` +
				`保存後、通常どおり作業を続行して構いません。`,
			{ deliverAs: "followUp" }
		);
	});
}
