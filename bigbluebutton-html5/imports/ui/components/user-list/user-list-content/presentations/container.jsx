import React from 'react';
import { withTracker } from 'meteor/react-meteor-data';
import Presentations from './component';
import { layoutSelectInput, layoutDispatch } from '../../../layout/context';

const PresentationsContainer = (props) => {
  const sidebarContent = layoutSelectInput((i) => i.sidebarContent);
  const { sidebarContentPanel } = sidebarContent;
  const layoutContextDispatch = layoutDispatch();

  return (
    <Presentations
      {...{
        sidebarContentPanel,
        layoutContextDispatch,
        ...props,
      }}
    />
  );
};

export default withTracker(({ isPresenter }) => ({
  presentationIsOpen: Session.equals('showUploadPresentationView', true),
  forcePresentationOpen: Session.equals('forcePresentationOpen', true),
}))(PresentationsContainer);
