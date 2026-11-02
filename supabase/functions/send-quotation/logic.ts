// Pure helpers for the send-quotation Edge Function. No Deno or network APIs are
// used here so the same code can be unit tested under Node.

export const DEFAULT_TIME_ZONE = 'America/Los_Angeles';
export const DEFAULT_VALIDITY_DAYS = 30;
// Statuses a customer may be emailed for. Draft, Rejected and Expired never are.
export const SENDABLE_STATUSES = ['Ready', 'Sent', 'Approved'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const EMAIL = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;

export class QuoteDataError extends Error {}

export type PdfLine = {
  text: string;
  size: number;
  strong: boolean;
  indent: number;
  gapBefore: number;
  gapAfter: number;
  tone?: 'brand';
  align?: 'right';
  project?: boolean;
  prefix?: string;
  table?: { kind: 'header' | 'row'; quantity: string };
};

export type Config = {
  from: string;
  replyTo: string | null;
  internalCopy: string | null;
  allowedRoles: string[];
  allowedOrigins: string[];
  cooldownSeconds: number;
  hourlyLimit: number;
};

const list = (value: string): string[] =>
  value.split(',').map((v) => v.trim()).filter(Boolean);

export const allowedOriginsFromEnv = (env: Record<string, string | undefined>): string[] =>
  list(env.QUOTATION_ALLOWED_ORIGINS ?? 'https://neliop96.github.io');

const boundedInt = (raw: string | undefined, fallback: number, min: number, max: number): number => {
  if (raw === undefined || raw.trim() === '') return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n >= min && n <= max ? n : fallback;
};

export const bareAddress = (value: string): string => {
  const match = /<([^<>]+)>\s*$/.exec(value);
  return (match ? match[1] : value).trim();
};
export const isEmail = (value: string): boolean => EMAIL.test(value);

// Reads the Supabase secrets. Sender addresses come from secrets only, and the
// role allow-list is explicit so new roles never gain email access implicitly.
export function parseConfig(env: Record<string, string | undefined>): Config | { error: string } {
  const from = (env.QUOTATION_EMAIL_FROM || '').trim();
  if (!from || !isEmail(bareAddress(from))) {
    return { error: 'QUOTATION_EMAIL_FROM is not configured with a valid sender address' };
  }
  const optional = (name: string): string | null | { error: string } => {
    const value = (env[name] || '').trim();
    if (!value) return null;
    return isEmail(bareAddress(value)) ? bareAddress(value) : { error: `${name} must be a valid email address` };
  };
  const replyTo = optional('QUOTATION_EMAIL_REPLY_TO');
  if (replyTo && typeof replyTo === 'object') return replyTo;
  const internalCopy = optional('QUOTATION_EMAIL_INTERNAL_COPY');
  if (internalCopy && typeof internalCopy === 'object') return internalCopy;
  const roles = list((env.QUOTATION_EMAIL_ROLES ?? 'admin,employee').toLowerCase());
  if (!roles.length) return { error: 'QUOTATION_EMAIL_ROLES must list at least one role' };
  return {
    from,
    replyTo: replyTo as string | null,
    internalCopy: internalCopy as string | null,
    allowedRoles: roles,
    allowedOrigins: allowedOriginsFromEnv(env),
    cooldownSeconds: boundedInt(env.QUOTATION_EMAIL_COOLDOWN_SECONDS, 60, 0, 86400),
    hourlyLimit: boundedInt(env.QUOTATION_EMAIL_HOURLY_LIMIT, 20, 1, 1000),
  };
}

export const roleAllowed = (role: unknown, allowed: string[]): boolean =>
  typeof role === 'string' && allowed.includes(role.trim().toLowerCase());

export function corsHeaders(origin: string | null, allowedOrigins: string[]): Record<string, string> {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
    Vary: 'Origin',
  };
  if (origin && allowedOrigins.includes(origin)) headers['Access-Control-Allow-Origin'] = origin;
  return headers;
}

export function todayInZone(timeZone: string, now: Date): string {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
      .formatToParts(now)
      .map(({ type, value }) => [type, value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function safeTimeZone(value: unknown): string {
  if (typeof value !== 'string' || !value) return DEFAULT_TIME_ZONE;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value });
    return value;
  } catch {
    return DEFAULT_TIME_ZONE;
  }
}

const isoDate = (value: unknown): string | null =>
  typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;

export function formatDate(value: unknown): string {
  const iso = isoDate(value);
  if (!iso) return '';
  const [year, month, day] = iso.split('-').map(Number);
  if (month < 1 || month > 12) return '';
  return `${MONTHS[month - 1]} ${day}, ${year}`;
}

export type Eligibility = { ok: true } | { ok: false; status: number; error: string };

// Server-side gate. Dates are compared as calendar strings in the business zone.
export function checkEligibility(quote: { status?: string; valid_until?: unknown }, today: string): Eligibility {
  const status = String(quote.status ?? '');
  if (status === 'Draft') {
    return { ok: false, status: 409, error: 'This estimate is a Draft. Mark it Ready before emailing it.' };
  }
  if (status === 'Rejected') {
    return { ok: false, status: 409, error: 'Rejected estimates cannot be emailed.' };
  }
  if (status === 'Expired') {
    return { ok: false, status: 409, error: 'This estimate has expired. Create a revision to send updated pricing.' };
  }
  if (!SENDABLE_STATUSES.includes(status)) {
    return { ok: false, status: 409, error: 'This estimate status cannot be emailed.' };
  }
  const validUntil = isoDate(quote.valid_until);
  if (status !== 'Approved' && validUntil && validUntil < today) {
    return {
      ok: false,
      status: 409,
      error:
        status === 'Sent'
          ? 'The validity period of this estimate has passed. Create a revision to send updated pricing.'
          : 'The validity period of this estimate has passed. Increase "Valid for (days)" and save before sending.',
    };
  }
  return { ok: true };
}

export type LimitDecision = { status: 429; error: string; retryAfter: number } | null;

export function evaluateSendLimits(input: {
  lastQuoteSendAt: string | null;
  userSendsLastHour: number;
  now: Date;
  cooldownSeconds: number;
  hourlyLimit: number;
}): LimitDecision {
  if (input.lastQuoteSendAt && input.cooldownSeconds > 0) {
    const elapsed = (input.now.getTime() - new Date(input.lastQuoteSendAt).getTime()) / 1000;
    if (elapsed >= 0 && elapsed < input.cooldownSeconds) {
      const retryAfter = Math.ceil(input.cooldownSeconds - elapsed);
      return {
        status: 429,
        error: `This quotation was just emailed. Wait ${retryAfter} seconds before sending it again.`,
        retryAfter,
      };
    }
  }
  if (input.userSendsLastHour >= input.hourlyLimit) {
    return {
      status: 429,
      error: `Email limit reached (${input.hourlyLimit} quotations per hour). Try again later.`,
      retryAfter: 3600,
    };
  }
  return null;
}

// Same key for the same saved version within one cooldown bucket, so a double
// click or retry cannot make Resend send two messages. Later deliberate resends use a new key.
export function idempotencyKey(
  quote: { id: string; updated_at?: string },
  detail: string,
  now: Date,
  cooldownSeconds: number,
): string {
  const bucket = Math.floor(now.getTime() / (Math.max(cooldownSeconds, 30) * 1000));
  return `quote-${quote.id}-${quote.updated_at ?? 'v0'}-${detail}-${bucket}`.replace(/[^A-Za-z0-9_.:-]/g, '-').slice(0, 250);
}

export const isMissingColumnError = (error: { code?: string; message?: string } | null | undefined): boolean =>
  Boolean(error && (error.code === '42703' || error.code === 'PGRST204' || /quote_version_at/.test(error.message || '')));

const text = (value: unknown, max: number): string => String(value ?? '').trim().slice(0, max);

const num = (value: unknown): number => {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) throw new QuoteDataError('Invalid quote price');
  return n;
};

export function computeTotals(quote: Record<string, any>) {
  const items = Array.isArray(quote.items) ? quote.items : [];
  if (!items.length) throw new QuoteDataError('Quotation has no items');
  const material = items.reduce((sum: number, item: any) => sum + num(item.qty) * num(item.cost), 0);
  const sell = material * (1 + num(quote.markup) / 100);
  const labor = num(quote.labor_hours) * num(quote.labor_rate);
  const tax = (sell * num(quote.tax_rate)) / 100;
  return { material, sell, labor, tax, total: sell + labor + tax };
}

// Customer PDFs use only the customer snapshot stored with the saved version.
export function pdfCustomer(quote: Record<string, any>): Record<string, any> {
  const snapshot = quote.customer_snapshot && typeof quote.customer_snapshot === 'object' ? quote.customer_snapshot : {};
  return Array.isArray(snapshot) ? {} : snapshot;
}

export const ascii = (value: unknown): string =>
  String(value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[\r\n]+/g, ' ')
    .replace(/[^\x20-\x7E]/g, '-');

export function dateLines(quote: Record<string, any>): string[] {
  const revision = Number(quote.revision_number) > 0;
  const original = formatDate(quote.original_estimate_date);
  const validUntil =
    formatDate(quote.valid_until) ||
    `${Number(quote.validity_days) || DEFAULT_VALIDITY_DAYS} days from the issue date`;
  if (revision) {
    return [
      `Revision: ${Number(quote.revision_number)}`,
      `Original Estimate Date: ${original || 'Not issued'}`,
      `Revision Date: ${formatDate(quote.revision_date) || 'Not issued'}`,
      `Valid Until: ${validUntil}`,
    ];
  }
  return [`Estimate Date: ${original || 'Not issued'}`, `Valid Until: ${validUntil}`];
}

export function customerProjectTitle(quote: Record<string, any>, override: unknown = ''): string {
  return text(override, 140)
    || text(quote.project_name, 140)
    || text(String(quote.notes ?? '').split(/\r?\n/, 1)[0], 140)
    || 'Automation Project';
}

export function buildPdfLines(
  quote: Record<string, any>,
  customer: Record<string, any>,
  detail: string,
  projectTitle: string,
): PdfLine[] {
  const t = computeTotals(quote);
  const items = quote.items as any[];
  const lines: PdfLine[] = [];
  const add = (
    value: unknown,
    size = 11,
    strong = false,
    indent = 0,
    gapBefore = 0,
    gapAfter = 0,
    options: Pick<PdfLine, 'tone' | 'align' | 'project' | 'prefix' | 'table'> = {},
  ) => lines.push({ text: ascii(value), size, strong, indent, gapBefore, gapAfter, ...options });

  add('PRECISION AUTOMATION', 21, true, 0, 0, 4, { tone: 'brand' });
  add(`Project Quotation ${text(quote.quote_number, 70)}`, 16, true, 0, 0, 8);
  const dates = dateLines(quote);
  dates.forEach((value, i) => {
    const prefix = value.slice(0, value.indexOf(':') + 1);
    add(value, 10.5, false, 0, 0, i === dates.length - 1 ? 8 : 0, { prefix });
  });
  add(`Customer: ${text(customer.name, 150)}`, 10.5, false, 0, 0, 0, { prefix: 'Customer:' });
  if (customer.contact) add(`Contact: ${text(customer.contact, 150)}`);
  if (customer.address) add(text(customer.address, 250));
  if (customer.email) add(text(customer.email, 150));
  add(projectTitle, 14.25, true, 0, 18, 12, { project: true });
  if (detail === 'materials') {
    add('Included Materials', 12, true, 0, 0, 5);
    add('Description', 10.5, true, 0, 0, 0, { table: { kind: 'header', quantity: 'Quantity' } });
    items.forEach((item) => {
      const description = `${text(item.description, 250)} (${text(item.part, 70)})`;
      add(description, 10.5, false, 0, 0, 0, { table: { kind: 'row', quantity: String(num(item.qty)) } });
    });
  }
  add(`Total Project Price: ${formatMoney(t.total)}`, 18, true, 0, 24, 0, { align: 'right' });
  if (quote.notes) {
    add('Project Scope / Notes', 14, true, 0, 24, 0);
    for (const part of String(quote.notes).split(/\r?\n/)) if (part.trim()) add(part, 10.5);
  }
  return lines;
}

export const formatMoney = (n: number): string =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(n);
