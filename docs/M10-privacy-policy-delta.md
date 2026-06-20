# M10 privacy-policy delta — for `JasonYeYuhe/soundpost-site`

Draft prose to merge into the hosted privacy policy
(`https://jasonyeyuhe.github.io/soundpost-site/privacy.html`) **before/with** the
ASC nutrition-label update (docs/M10-DEVPLAN.md §S5/§6). M9 added no collected
data; M10 is the first milestone that sends anything off-device for delivery.

---

## Cloud-backed reminder delivery

To make a **sealed capsule's far-future reminder** arrive on its date even when
it's years away (beyond what an on-device schedule can reliably hold), Soundpost
can enqueue the reminder on its own server (Supabase) and deliver it via Apple
Push Notification service. This is **opt-out** and **best-effort** — "cloud-
backed," never guaranteed.

**What leaves your device for this — and only this:**

- your device's **Apple Push Notification token** (so Apple can deliver the alert
  to this device);
- an **anonymous per-user key** — a random value Soundpost generates and stores
  in your private iCloud, used only to group your own devices' reminders. It is
  not your name, email, Apple ID, or any identity, and is never combined with
  data from other apps or data brokers;
- **content-free schedule metadata**: the capsule's identifier, the reminder's
  date/time + time zone, and the kind of reminder.

**What never leaves your device:** the capsule's audio, your note, your mood, and
your place. None of these are ever sent to the server or carried in the push. The
push is only a signal; the capsule is read from your own device's store.

**This data is used only to deliver your reminders** (App Functionality). It is
not used to track you and is not linked to your identity.

**Signed-out / offline:** if you're not signed into iCloud (or are offline),
nothing is sent — reminders use your device's local schedule, and the app is
fully functional.

**Retention & deletion.** A reminder's server record is removed when you delete
the capsule, unseal it, when it resurfaces, or when you tap **Delete my cloud
data** in the app (which removes the schedule and device tokens Soundpost keeps
on its server and stops further collection). Tokens that Apple reports as no
longer valid are pruned automatically.

---

### Publish checklist (Jason)
- [ ] Merge the above into `privacy.html` on the `soundpost-site` `main` branch
      (reuse the M9 policy-update flow), live on GitHub Pages.
- [ ] Update the **ASC App Privacy nutrition label** to match: add **Identifiers
      → Device ID** and **Identifiers → User ID** (App Functionality, *not linked
      to you*, *not used to track you*); add **Other Data** for the schedule
      metadata (App Functionality, not linked, not tracking). Keep Crash/
      Diagnostics as-is. Publish **with or after** the policy goes live, never
      before.
- [ ] Confirm no new Required-Reason API was added (none in M10).
