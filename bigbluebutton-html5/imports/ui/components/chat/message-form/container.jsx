import React, { PureComponent } from 'react';
import { withTracker } from 'meteor/react-meteor-data';
import _ from 'lodash';
import { makeCall } from '/imports/ui/services/api';
import ChatForm from './component';
import ChatService from '../service';

const CHAT_CONFIG = Meteor.settings.public.chat;
const START_TYPING_THROTTLE_INTERVAL = 2000;

class ChatContainer extends PureComponent {
  render() {
    return (
      <ChatForm {...this.props} />
    );
  }
}

export default withTracker(() => {
  const cleanScrollAndSendMessage = (message) => {
    ChatService.setUserSentMessage(true);
    return ChatService.sendGroupMessage(message);
  };

  const startUserTyping = chatId => makeCall('startUserTyping', chatId);

  const stopUserTyping = () => makeCall('stopUserTyping');

  return {
    startUserTyping: _.throttle(startUserTyping, START_TYPING_THROTTLE_INTERVAL),
    stopUserTyping,
    UnsentMessagesCollection: ChatService.UnsentMessagesCollection,
    minMessageLength: CHAT_CONFIG.min_message_length,
    maxMessageLength: CHAT_CONFIG.max_message_length,
    handleSendMessage: cleanScrollAndSendMessage,
  };
})(ChatContainer);
