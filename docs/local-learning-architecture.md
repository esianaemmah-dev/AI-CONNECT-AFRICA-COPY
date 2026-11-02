# Local learning and staff access

The app continues to use Riverpod, Drift, GoRouter, UDP/mDNS discovery,
SelectiveSyncManager and the existing signed, encrypted class protocol. No new
dependency or hosted service is required.

## Learners

Class membership grants access to shared materials and registers their subjects.
Joining requires the teacher's approval and confirmation of the returned class
details. PDFs download independently of text extraction and quiz generation.
Learner PINs remain optional. Without one, another person using the device can
open that learner's profile; class access does not prove personal identity.
Creating a profile does not enrol it in a class. Class assignment requires an
authenticated Admin or assigned class teacher; the learner join flow still
requires teacher approval. School cloud also requires personal staff sign-in.

LearnerSyncController owns foreground discovery and transfers. Home, My notes,
and Sync share its state and coalesce transfer requests. Approved classes sync
when a teacher appears and when the app resumes. Discovery alone never enrols
anybody. Backgrounding cancels transfers; existing partial files resume later.
Automatic discovery events are debounced for 30 seconds. Connection help retains
the manual-address fallback. Discovery hints never replace signature validation.

Reading positions and the last opened document are scoped to each learner.
Legacy document positions move to the current learner once, then the old
unscoped preference is removed.

## Staff

Staff access uses personal teacher or Admin credentials. The shared Teachers PIN
is no longer an authorization boundary. Existing unlock links redirect to staff
sign-in. Leaving the staff area or handing over the device clears staff access.

Staff leases expire after five idle minutes or one hour total. Backgrounding
locks staff access, and pointer/keyboard activity cannot revive an expired
lease. Services reject revoked leases; production Policy additionally checks
the current authenticated actor. Sensitive Admin changes require authentication
within the last 60 seconds. Credential resets invalidate affected leases.

Five failed local account checks produce a persisted 30-second cooldown.
Verification is serialized per account to avoid concurrent-attempt races.

## Upgrade and recovery

Schema 38 adds nullable Admin recovery salt/hash fields and removes stored
plaintext PIN copies while keeping existing PIN hashes and school records.
Startup also clears legacy plaintext preferences and columns. Existing Admins
receive a recovery code after their next successful authentication. New Admins
receive one during setup. Save it privately: only its hash remains on the device.

Recovery requires the saved code, consumes it, and revokes outstanding sessions.
The next authenticated sign-in creates a replacement code. Creating a code in
Admin settings also replaces the previous code. Recovery material is local and
excluded from ordinary school-record exports; signed Admin takeover clears old
recovery material and retains its existing passphrase checks.

QR scanning, OS-backed key storage and full-disk encryption are deferred under
the existing-dependencies constraint. These changes strengthen application
access controls, not protection against someone who can copy or alter app files.
