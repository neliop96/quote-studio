import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1';
import {
  DEFAULT_TIME_ZONE,
  QuoteDataError,
  allowedOriginsFromEnv,
  buildPdfLines,
  checkEligibility,
  corsHeaders,
  customerProjectTitle,
  evaluateSendLimits,
  idempotencyKey,
  isEmail,
  isMissingColumnError,
  parseConfig,
  pdfCustomer,
  roleAllowed,
  safeTimeZone,
  todayInZone,
} from './logic.ts';
import type { PdfLine } from './logic.ts';

// Required secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
// (provided by Supabase), RESEND_API_KEY and QUOTATION_EMAIL_FROM. Optional:
// QUOTATION_EMAIL_REPLY_TO, QUOTATION_EMAIL_INTERNAL_COPY, QUOTATION_EMAIL_ROLES,
// QUOTATION_ALLOWED_ORIGINS, QUOTATION_EMAIL_COOLDOWN_SECONDS, QUOTATION_EMAIL_HOURLY_LIMIT.
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const env = Deno.env.toObject();
const config = parseConfig(env);
const allowedOrigins = allowedOriginsFromEnv(env);

const text = (v: unknown, max = 4000) => String(v ?? '').trim().slice(0, max);
const base64 = (bytes: Uint8Array) => {
  let out = '';
  for (let i = 0; i < bytes.length; i += 8192) out += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(out);
};

async function renderPdf(lines: PdfLine[]): Promise<string> {
  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const W = 612, H = 792, M = 40;
  const contentWidth = W - 2 * M;
  let page = pdf.addPage([W, H]);
  let y = H - M;
  const color = rgb(0x18 / 255, 0x23 / 255, 0x36 / 255);
  const brand = rgb(0x16 / 255, 0x4e / 255, 0x93 / 255);
  const rule = rgb(0xcc / 255, 0xcc / 255, 0xcc / 255);
  const addPage = () => {
    page = pdf.addPage([W, H]);
    y = H - M;
  };
  const ensureSpace = (height: number) => {
    if (y - height < M) {
      addPage();
      return true;
    }
    return false;
  };
  const wrap = (value: string, font: typeof regular, size: number, maxWidth: number): string[] => {
    const output: string[] = [];
    for (const paragraph of value.split('\n')) {
      if (!paragraph) {
        output.push('');
        continue;
      }
      let line = '';
      for (const word of paragraph.split(/\s+/)) {
        let part = word;
        while (font.widthOfTextAtSize(part, size) > maxWidth) {
          let splitAt = 1;
          while (splitAt < part.length && font.widthOfTextAtSize(part.slice(0, splitAt + 1), size) <= maxWidth) splitAt++;
          if (line) {
            output.push(line);
            line = '';
          }
          output.push(part.slice(0, splitAt));
          part = part.slice(splitAt);
        }
        const trial = line ? `${line} ${part}` : part;
        if (font.widthOfTextAtSize(trial, size) > maxWidth && line) {
          output.push(line);
          line = part;
        } else {
          line = trial;
        }
      }
      if (line) output.push(line);
    }
    return output;
  };
  const drawText = (
    value: string,
    size: number,
    font: typeof regular,
    x: number,
    maxWidth: number,
    textColor = color,
    align: 'left' | 'right' = 'left',
  ) => {
    const lineHeight = size * 1.5;
    for (const line of wrap(value, font, size, maxWidth)) {
      ensureSpace(lineHeight);
      y -= lineHeight;
      const width = font.widthOfTextAtSize(line, size);
      page.drawText(line, {
        x: align === 'right' ? x + maxWidth - width : x,
        y: y + (lineHeight - size) / 2,
        size,
        font,
        color: textColor,
      });
    }
  };
  const drawPrefixedText = (
    value: string,
    prefix: string,
    size: number,
    x: number,
    maxWidth: number,
  ) => {
    const gap = 4;
    const prefixWidth = bold.widthOfTextAtSize(prefix, size);
    const remainder = value.slice(prefix.length).trimStart();
    const firstLineWidth = Math.max(1, maxWidth - prefixWidth - gap);
    const firstLines = wrap(remainder, regular, size, firstLineWidth);
    const lineHeight = size * 1.5;
    ensureSpace(lineHeight);
    y -= lineHeight;
    const baseline = y + (lineHeight - size) / 2;
    page.drawText(prefix, { x, y: baseline, size, font: bold, color });
    page.drawText(firstLines[0] || '', {
      x: x + prefixWidth + gap,
      y: baseline,
      size,
      font: regular,
      color,
    });
    for (const line of firstLines.slice(1)) {
      ensureSpace(lineHeight);
      y -= lineHeight;
      page.drawText(line, { x, y: y + (lineHeight - size) / 2, size, font: regular, color });
    }
  };
  const drawTableHeader = (description = 'Description', quantity = 'Quantity') => {
    const descriptionWidth = contentWidth * 0.78;
    const quantityWidth = contentWidth - descriptionWidth;
    const pad = 7;
    const fontSize = 10.5;
    const lineHeight = fontSize * 1.5;
    const height = lineHeight + pad * 2;
    ensureSpace(height);
    y -= lineHeight;
    page.drawText(description, {
      x: M + pad,
      y: y + (lineHeight - fontSize) / 2,
      size: fontSize,
      font: bold,
      color,
    });
    page.drawText(quantity, {
      x: M + descriptionWidth + pad,
      y: y + (lineHeight - fontSize) / 2,
      size: fontSize,
      font: bold,
      color,
    });
    page.drawLine({ start: { x: M, y: y - pad }, end: { x: W - M, y: y - pad }, thickness: 0.6, color: rule });
    y -= pad;
  };
  const drawTableRow = (description: string, quantity: string) => {
    const descriptionWidth = contentWidth * 0.78;
    const quantityWidth = contentWidth - descriptionWidth;
    const pad = 7;
    const fontSize = 10.5;
    const font = regular;
    const descriptionLines = wrap(description, font, fontSize, descriptionWidth - pad * 2);
    const quantityLines = wrap(quantity, font, fontSize, quantityWidth - pad * 2);
    const lineHeight = fontSize * 1.5;
    const rowHeight = Math.max(descriptionLines.length, quantityLines.length) * lineHeight + pad * 2;
    if (ensureSpace(rowHeight)) drawTableHeader();
    for (let i = 0; i < Math.max(descriptionLines.length, quantityLines.length); i++) {
      y -= lineHeight;
      page.drawText(descriptionLines[i] || '', {
        x: M + pad,
        y: y + (lineHeight - fontSize) / 2,
        size: fontSize,
        font,
        color,
      });
      page.drawText(quantityLines[i] || '', {
        x: M + descriptionWidth + pad,
        y: y + (lineHeight - fontSize) / 2,
        size: fontSize,
        font,
        color,
      });
    }
    page.drawLine({ start: { x: M, y: y - pad }, end: { x: W - M, y: y - pad }, thickness: 0.6, color: rule });
    y -= pad;
  };
  for (const entry of lines) {
    if (entry.table?.kind === 'header') {
      y -= entry.gapBefore;
      drawTableHeader(entry.text, entry.table.quantity);
      y -= entry.gapAfter;
      continue;
    }
    if (entry.table?.kind === 'row') {
      drawTableRow(entry.text, entry.table.quantity);
      y -= entry.gapAfter;
      continue;
    }
    const font = entry.strong ? bold : regular;
    const lineHeight = entry.size * 1.5;
    const maxWidth = contentWidth - entry.indent;
    y -= entry.gapBefore;
    if (entry.project) {
      const blockPadding = 12;
      ensureSpace(lineHeight + blockPadding * 2 + 2);
      page.drawLine({ start: { x: M, y: y - blockPadding / 2 }, end: { x: W - M, y: y - blockPadding / 2 }, thickness: 0.7, color: rgb(0xdc / 255, 0xe3 / 255, 0xeb / 255) });
      y -= blockPadding;
      drawText(entry.text, entry.size, font, M, maxWidth);
      y -= blockPadding;
      page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.7, color: rgb(0xdc / 255, 0xe3 / 255, 0xeb / 255) });
      y -= blockPadding;
    } else if (entry.prefix) {
      drawPrefixedText(entry.text, entry.prefix, entry.size, M + entry.indent, maxWidth);
    } else {
      drawText(
        entry.text,
        entry.size,
        font,
        M + entry.indent,
        maxWidth,
        entry.tone === 'brand' ? brand : color,
        entry.align === 'right' ? 'right' : 'left',
      );
    }
    y -= entry.gapAfter;
  }
  return base64(await pdf.save());
}

Deno.serve(async (req: Request) => {
  const headers = corsHeaders(req.headers.get('Origin'), allowedOrigins);
  const respond = (status: number, body: unknown, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { ...headers, ...extra } });

  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return respond(405, { error: 'Method not allowed' });
  try {
    if ('error' in config) {
      console.error('send-quotation configuration error:', config.error);
      return respond(500, { error: 'Email sending is not configured. Contact an administrator.' });
    }
    if (!RESEND_API_KEY) return respond(500, { error: 'Resend API key is not configured' });

    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return respond(401, { error: 'Sign in required' });
    const auth = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false },
    });
    const { data: { user }, error: userError } = await auth.auth.getUser(jwt);
    if (userError || !user) return respond(401, { error: 'Invalid session' });

    const approvalCheck = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false },
    });
    const { data: approved, error: approvalError } = await approvalCheck.rpc('is_account_approved');
    if (approvalError) {
      console.error('Account approval check failed:', approvalError.message);
      return respond(500, { error: 'Unable to verify account approval' });
    }
    if (approved !== true) return respond(403, { error: 'Account approval required' });

    const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
    const { data: profile, error: profileError } = await admin.from('profiles').select('role').eq('id', user.id).maybeSingle();
    if (profileError) {
      console.error('Profile lookup failed:', profileError.message);
      return respond(500, { error: 'Unable to verify permissions' });
    }
    if (!roleAllowed(profile?.role, config.allowedRoles)) return respond(403, { error: 'Your role is not permitted to email quotations' });

    let input: any;
    try {
      input = await req.json();
    } catch {
      return respond(400, { error: 'Invalid request body' });
    }
    const id = text(input?.quote_id, 80);
    if (!/^[0-9a-f-]{36}$/i.test(id)) return respond(400, { error: 'Invalid quotation ID' });
    const detail = input.detail === 'materials' ? 'materials' : 'project';
    const title = text(input.project_title, 140);
    const subject = text(input.subject, 180) || 'Precision Automation quotation';
    const message = text(input.message, 4000) || 'Please find attached our quotation.';

    const { data: quote, error: quoteError } = await admin.from('quotes').select('*').eq('id', id).maybeSingle();
    if (quoteError) {
      console.error('Quote lookup failed:', quoteError.message);
      return respond(500, { error: 'Unable to load the quotation' });
    }
    if (!quote) return respond(404, { error: 'Quotation not found' });

    // Business date, in the same zone the database uses for estimate dates.
    const now = new Date();
    let today: string | null = null;
    const businessDate = await admin.rpc('quote_studio_business_date');
    if (!businessDate.error && /^\d{4}-\d{2}-\d{2}$/.test(String(businessDate.data))) today = String(businessDate.data);
    if (!today) {
      const settings = await admin.from('quote_settings').select('quote_time_zone').eq('id', 1).maybeSingle();
      today = todayInZone(safeTimeZone(settings.data?.quote_time_zone ?? DEFAULT_TIME_ZONE), now);
    }
    const eligibility = checkEligibility(quote, today);
    if (!eligibility.ok) return respond(eligibility.status, { error: eligibility.error });

    // Duplicate-send protection and rate limiting. Fail closed if the log is unreadable.
    const hourAgo = new Date(now.getTime() - 3600 * 1000).toISOString();
    const [last, perUser] = await Promise.all([
      admin.from('quotation_email_log').select('created_at').eq('quote_id', quote.id).order('created_at', { ascending: false }).limit(1),
      admin.from('quotation_email_log').select('id', { count: 'exact', head: true }).eq('sent_by', user.id).gte('created_at', hourAgo),
    ]);
    if (last.error || perUser.error) {
      console.error('Send limit lookup failed:', last.error?.message || perUser.error?.message);
      return respond(500, { error: 'Unable to check email limits' });
    }
    const limited = evaluateSendLimits({
      lastQuoteSendAt: last.data?.[0]?.created_at ?? null,
      userSendsLastHour: perUser.count ?? 0,
      now,
      cooldownSeconds: config.cooldownSeconds,
      hourlyLimit: config.hourlyLimit,
    });
    if (limited) return respond(limited.status, { error: limited.error }, { 'Retry-After': String(limited.retryAfter) });

    let live: Record<string, any> | null = null;
    if (quote.customer_id) {
      const found = await admin.from('customers').select('*').eq('id', quote.customer_id).maybeSingle();
      if (found.error) {
        console.error('Customer lookup failed:', found.error.message);
        return respond(500, { error: 'Unable to load the customer record' });
      }
      live = found.data;
    }
    const customer = pdfCustomer(quote);
    // The recipient is the customer's current address; the PDF uses the saved snapshot.
    const to = text(live?.email || quote.customer_snapshot?.email, 254);
    if (!isEmail(to)) return respond(400, { error: 'Add a valid email address to the customer record' });

    const pdf = await renderPdf(buildPdfLines(quote, customer, detail, customerProjectTitle(quote, title)));
    const filename = `Quotation_${text(quote.quote_number, 70).replace(/[^a-zA-Z0-9_-]/g, '_')}.pdf`;
    const payload: Record<string, unknown> = {
      from: config.from,
      to: [to],
      subject,
      text: message,
      attachments: [{ filename, content: pdf }],
    };
    if (config.replyTo) payload.reply_to = config.replyTo;
    if (config.internalCopy && config.internalCopy.toLowerCase() !== to.toLowerCase()) payload.bcc = [config.internalCopy];
    if (!config.internalCopy) console.warn('QUOTATION_EMAIL_INTERNAL_COPY is not set; no internal copy was sent');

    const sent = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey(quote, detail, now, config.cooldownSeconds),
      },
      body: JSON.stringify(payload),
    }).catch((error) => {
      console.error('Resend request failed:', error);
      return null;
    });
    if (!sent) return respond(502, { error: 'Could not reach the email provider. Nothing was sent; try again.' });
    const result = await sent.json().catch(() => ({}));
    if (!sent.ok) return respond(502, { error: `Resend rejected the email: ${text(result.message || result.name || sent.status, 300)}` });

    // Resend's acceptance is not proof of inbox delivery. The log row is tied to the exact saved
    // version that was rendered, so a later edit can never be marked Sent by this message.
    const row = {
      quote_id: quote.id,
      quote_number: quote.quote_number,
      customer_email: to,
      sent_by: user.id,
      resend_id: result.id || null,
      subject,
      detail,
      delivery_status: 'submitted',
    };
    let logResult = await admin.from('quotation_email_log').insert({ ...row, quote_version_at: quote.updated_at });
    if (isMissingColumnError(logResult.error)) logResult = await admin.from('quotation_email_log').insert(row);
    const logged = !logResult.error;
    if (!logged) console.error('Quotation email log insert failed:', logResult.error?.message);

    let status: string = quote.status;
    let statusUpdated = false;
    const warnings: string[] = [];
    if (quote.status === 'Ready') {
      if (!result.id) {
        warnings.push('The provider did not return a message id, so the estimate stays Ready.');
      } else {
        // Only moves the exact version that was emailed; a concurrent edit changes updated_at.
        const moved = await admin.from('quotes').update({ status: 'Sent' }).eq('id', quote.id).eq('status', 'Ready').eq('updated_at', quote.updated_at).select('id');
        if (moved.error) {
          console.error('Quotation status update failed:', moved.error.message);
          warnings.push('The email was accepted but the estimate status could not be updated.');
        } else if (moved.data?.length === 1) {
          status = 'Sent';
          statusUpdated = true;
        } else {
          warnings.push('The estimate was changed while the email was being sent, so it stays Ready. The email contained the previously saved version.');
        }
      }
    }
    if (!logged) warnings.push('The send could not be recorded in the email log.');
    return respond(200, { ok: true, id: result.id ?? null, logged, status, status_updated: statusUpdated, ...(warnings.length ? { warning: warnings.join(' ') } : {}) });
  } catch (e) {
    if (e instanceof QuoteDataError) return respond(400, { error: e.message });
    console.error(e);
    return respond(500, { error: 'Unable to send quotation. Check Edge Function logs.' });
  }
});
