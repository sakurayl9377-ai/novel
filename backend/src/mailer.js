import nodemailer from 'nodemailer';
import { config } from './config.js';

let transporter;

function getTransporter() {
  if (!config.smtp.host) return null;
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host: config.smtp.host,
      port: config.smtp.port,
      secure: config.smtp.secure,
      auth:
        config.smtp.user && config.smtp.pass
          ? { user: config.smtp.user, pass: config.smtp.pass }
          : undefined,
    });
  }
  return transporter;
}

export async function sendVerificationEmail(email, code) {
  const mailer = getTransporter();
  if (!mailer) {
    if (config.allowDevAuthCodes) {
      console.log(`[dev email code] ${email}: ${code}`);
      return { delivered: false, devCode: code };
    }
    const error = new Error('SMTP is not configured');
    error.statusCode = 503;
    throw error;
  }

  await mailer.sendMail({
    from: config.smtp.from,
    to: email,
    subject: '小说 App 邮箱验证码',
    text: `你的验证码是 ${code}，10 分钟内有效。若非本人操作，请忽略本邮件。`,
    html: `<p>你的验证码是 <strong style="font-size:20px">${code}</strong>，10 分钟内有效。</p><p>若非本人操作，请忽略本邮件。</p>`,
  });
  return { delivered: true };
}
