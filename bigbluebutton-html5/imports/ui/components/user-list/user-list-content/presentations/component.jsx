import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import Icon from '/imports/ui/components/common/icon/component';
import Styled from './styles';
import { ACTIONS, PANELS } from '../../../layout/enums';

const intlMessages = defineMessages({
  presentationLabel: {
    id: 'app.presentation.presentationPaneTitle', // Make presentation
    description: 'label for user-list presentation button',
  },
});

const Presentations = ({
  intl,
  isPresenter,
  presentationIsOpen,
  forcePresentationOpen,
  sidebarContentPanel,
  layoutContextDispatch,
}) => {
  // if (!isPresenter) return null;
  if (!forcePresentationOpen) return null;

  const handleClickTogglePresentation = () => {
    layoutContextDispatch({
      type: ACTIONS.SET_SIDEBAR_CONTENT_IS_OPEN,
      value: sidebarContentPanel !== PANELS.PRESENTATIONS,
    });
    layoutContextDispatch({
      type: ACTIONS.SET_SIDEBAR_CONTENT_PANEL,
      value: sidebarContentPanel === PANELS.PRESENTATIONS
        ? PANELS.NONE
        : PANELS.PRESENTATIONS,
    });
  };

  return (
    <Styled.Messages>
      <Styled.Container>
        <Styled.SmallTitle>
          {intl.formatMessage(intlMessages.presentationLabel)}
        </Styled.SmallTitle>
      </Styled.Container>
      <Styled.List>
        <Styled.ScrollableList>
          <Styled.ListItem
            role="button"
            tabIndex={0}
            data-test="presentationMenuButton"
            onClick={handleClickTogglePresentation}
            onKeyPress={() => {}}
          >
            <Icon iconName="presentations" />
            <span>{intl.formatMessage(intlMessages.presentationLabel)}</span>
          </Styled.ListItem>
        </Styled.ScrollableList>
      </Styled.List>
    </Styled.Messages>
  );
};

export default injectIntl(Presentations);

Presentations.propTypes = {
  intl: PropTypes.shape({
    formatMessage: PropTypes.func.isRequired,
  }).isRequired,
  isPresenter: PropTypes.bool.isRequired,
  presentationIsOpen: PropTypes.bool.isRequired,
  forcePresentationOpen: PropTypes.bool.isRequired,
};
