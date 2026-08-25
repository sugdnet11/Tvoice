import { GuestConference } from './GuestConference';

export default async function ConferenceInvitePage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  return <GuestConference inviteToken={token} />;
}
